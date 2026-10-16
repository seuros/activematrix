# frozen_string_literal: true

module ActiveMatrix
  module Bot
    # A bot. One instance handles one event, the way a controller handles one
    # request, inside the transaction that marks the event handled: what the
    # handler writes (replies, memory, records of your own) commits with it,
    # or not at all.
    #
    #   class CaptainBot < ApplicationBot
    #     setting :greeting, :string, default: 'Welcome aboard'
    #
    #     command :deploy, 'Deploy a target', power: :moderator do |target, force: false|
    #       reply "Deploying #{target}#{' (forced)' if force}", thread: true
    #     end
    #
    #     on 'm.room.member', if: -> { content['membership'] == 'join' && sender != me } do
    #       reply "#{settings.greeting}, #{sender}!"
    #     end
    #
    #     on_invite { join }
    #   end
    class Base
      include ActiveSupport::Rescuable
      include Actions

      POWER = { moderator: 50, admin: 100 }.freeze

      Command = Data.define(:name, :description, :block, :raw, :guards)
      Handler = Data.define(:event_type, :block, :guards)
      Setting = Data.define(:name, :type, :default)
      Guards = Data.define(:dm, :power, :condition)

      class_attribute :command_prefixes, instance_writer: false, default: ['!'].freeze
      class_attribute :commands, instance_writer: false, default: {}.freeze
      class_attribute :handlers, instance_writer: false, default: [].freeze
      class_attribute :invite_handlers, instance_writer: false, default: [].freeze
      class_attribute :agent_message_handlers, instance_writer: false, default: {}.freeze
      class_attribute :setting_definitions, instance_writer: false, default: {}.freeze
      class_attribute :before_command_callbacks, instance_writer: false, default: [].freeze

      class << self
        # `!name args`. Positional block parameters take the arguments;
        # keyword parameters take `--flags`. `raw: true` passes the text after
        # the command name instead. Guards: `dm: true/false`, `power:` (a
        # level, `:moderator` or `:admin`), `if:` (evaluated in the bot).
        def command(name, description = nil, raw: false, dm: nil, power: nil, if: nil, &block)
          raise ArgumentError, "command #{name} needs a block" unless block

          guards = Guards.new(dm:, power: power_level(power), condition: binding.local_variable_get(:if))
          command = Command.new(name: name.to_s.downcase, description:, block:, raw:, guards:)
          self.commands = commands.merge(command.name => command).freeze
        end

        # Any event of `event_type` that is not a command.
        def on(event_type, dm: nil, power: nil, if: nil, &block)
          raise ArgumentError, "on #{event_type} needs a block" unless block

          guards = Guards.new(dm:, power: power_level(power), condition: binding.local_variable_get(:if))
          self.handlers = [*handlers, Handler.new(event_type: event_type.to_s, block:, guards:)].freeze
        end

        def on_message(**, &) = on('m.room.message', **, &)

        def on_invite(&block)
          self.invite_handlers = [*invite_handlers, block].freeze
        end

        # Handles `deliver_to(this_agent, topic, payload)` from another agent.
        def on_agent_message(topic, &block)
          self.agent_message_handlers = agent_message_handlers.merge(topic.to_s => block).freeze
        end

        # A typed setting, read from the agent's `settings`.
        def setting(name, type = :string, default: nil)
          definition = Setting.new(name: name.to_s, type:, default:)
          self.setting_definitions = setting_definitions.merge(definition.name => definition).freeze
        end

        def before_command(*methods, only: nil, except: nil)
          callbacks = methods.map { [it, Array(only).map(&:to_s), Array(except).map(&:to_s)] }
          self.before_command_callbacks = [*before_command_callbacks, *callbacks].freeze
        end

        def prefix(*prefixes)
          self.command_prefixes = prefixes.map(&:to_s).freeze
        end

        # Entry point for one inbox event.
        def dispatch(agent:, event:) = new(agent:, event:).dispatch

        # Entry point for one agent message.
        def receive(agent:, message:) = new(agent:, message:).receive

        private

        def power_level(power)
          case power
          when nil, Integer then power
          else POWER.fetch(power.to_sym) { raise ArgumentError, "unknown power #{power.inspect}" }
          end
        end
      end

      attr_reader :agent, :event, :message

      def initialize(agent:, event: nil, message: nil)
        @agent = agent
        @event = event
        @message = message
      end

      def dispatch
        ActiveSupport::Notifications.instrument('dispatch.active_matrix', agent: agent.name,
                                                                          event_id: event.event_id,
                                                                          event_type: event.event_type) do
          handle
        end
      rescue StandardError => e
        rescue_with_handler(e) || raise
      end

      def receive
        handler = agent_message_handlers[message.topic]
        instance_exec(message.payload, &handler) if handler
      rescue StandardError => e
        rescue_with_handler(e) || raise
      end

      # -- What a handler reads -----------------------------------------------

      def room_id = event&.room_id
      def sender = event&.sender
      def content = event&.content || {}
      def body = content['body'].to_s

      # The agent's own user id.
      def me = agent.user_id

      # The mirrored room; nil until the daemon has synced it.
      def room
        return @room if defined?(@room)

        @room = room_id && Room.find_by(agent_id: agent.id, room_id:)
      end

      def direct? = room&.direct? || false

      def settings = @settings ||= Settings.new(agent.settings, setting_definitions)

      delegate :memory, to: :agent
      # Not `delegate`: its generated method would not resolve Memory to
      # ActiveMatrix::Memory.
      def global = Memory.global # rubocop:disable Rails/Delegate
      def session = @session ||= ChatSession.for(agent:, room_id:, user_id: sender)
      def conversation = session.memory

      private

      def handle
        return run_invite if event.invite?

        parsed = command_text && CommandParser.parse(command_text, prefixes: command_prefixes)
        if parsed && (command = commands[parsed.name])
          run_command(command, parsed)
        elsif parsed&.name == 'help'
          reply help_text, notice: true
        else
          run_handlers
        end
      end

      # Commands come from people: plain text messages, not notices (which
      # bots send to each other) or edits.
      def command_text
        return unless event.event_type == 'm.room.message' && content['msgtype'] == 'm.text'
        return if content.dig('m.relates_to', 'rel_type') == 'm.replace'

        body
      end

      def run_invite
        invite_handlers.each { instance_exec(&it) }
      end

      def run_handlers
        handlers.each do |handler|
          next unless handler.event_type == event.event_type && allowed?(handler.guards)

          instance_exec(&handler.block)
        end
      end

      def run_command(command, parsed)
        return unless allowed?(command.guards, explain: command.name)

        catch(:halt) do
          run_before_command(command.name)
          ActiveSupport::Notifications.instrument('command.active_matrix', agent: agent.name, command: command.name) do
            invoke(command, parsed)
          end
        end
      end

      # Stops the command from a before_command callback.
      def halt! = throw(:halt)

      def run_before_command(name)
        before_command_callbacks.each do |method, only, except|
          next if only.any? && only.exclude?(name)
          next if except.include?(name)

          send(method)
        end
      end

      def invoke(command, parsed)
        return instance_exec(parsed.rest, &command.block) if command.raw

        call = Arguments.new(command.block, parsed)
        unless call.valid?
          return reply("Usage: #{command_prefixes.first}#{command.name} #{call.usage}".strip,
                       notice: true)
        end

        instance_exec(*call.positional, **call.keywords, &command.block)
      end

      def allowed?(guards, explain: nil)
        return false if !guards.dm.nil? && guards.dm != direct?
        return false if guards.condition && !instance_exec(&guards.condition)
        return true unless guards.power

        level = room&.power_level(sender) || 0
        return true if level >= guards.power

        reply("#{command_prefixes.first}#{explain} needs power level #{guards.power}.", notice: true) if explain
        false
      end

      def help_text
        lines = commands.values.map { "#{command_prefixes.first}#{it.name}  #{it.description}".rstrip }
        (['Commands:'] + lines.sort).join("\n")
      end
    end
  end
end
