# frozen_string_literal: true

module ActiveMatrix::Bot
  # Base class for multi-instance bot support
  class MultiInstanceBase < Base
    attr_reader :agent_record

    def initialize(client_or_agent, **params)
      # Handle both client and agent record initialization
      if client_or_agent.respond_to?(:homeserver) && !client_or_agent.respond_to?(:client) # It's a client
        super
        @agent_record = params[:agent_record]
      else # It's an agent record
        @agent_record = client_or_agent
        super(@agent_record.client, **params)
      end

      setup_agent_context if @agent_record
    end

    # Access agent-specific memory
    def memory
      @memory ||= ActiveMatrix::Memory.for_agent(@agent_record)
    end

    # Access conversation memory
    def conversation_memory(user_id = nil, room_id = nil)
      user_id ||= event[:sender] if in_event?
      room_id ||= event[:room_id] if in_event?

      return nil unless user_id && room_id

      @conversation_memories ||= {}
      @conversation_memories["#{user_id}/#{room_id}"] ||=
        ActiveMatrix::Memory.for_conversation(@agent_record, user_id, room_id)
    end

    # Access global memory
    def global_memory
      ActiveMatrix::Memory.global
    end

    # Get current conversation context
    def conversation_context
      conversation_memory&.context || {}
    end

    # Update conversation context
    def update_context(data)
      conversation_memory&.update_context(data)
    end

    # Remember something in conversation
    def remember_in_conversation(key, &)
      conversation_memory&.remember(key, &)
    end

    # Agent state helpers
    def agent_name
      @agent_record&.name || settings.bot_name
    end

    def agent_state
      @agent_record&.state || 'unknown'
    end

    def mark_busy!
      @agent_record&.start_processing! if @agent_record&.may_start_processing?
    end

    def mark_idle!
      @agent_record&.finish_processing! if @agent_record&.may_finish_processing?
    end

    # Inter-agent communication
    def broadcast_to_agents(selector, data)
      return unless defined?(AgentRegistry)

      registry = AgentRegistry.instance
      registry.broadcast_to(selector) do |agent_bot|
        agent_bot.receive_broadcast(data, from: self)
      end
    end

    def send_to_agent(agent_name, data)
      return unless defined?(AgentRegistry)

      registry = AgentRegistry.instance
      entry = registry.get_by_name(agent_name)

      if entry
        entry[:instance].receive_message(data, from: self)
        true
      else
        logger.warn "Agent #{agent_name} not found or not running"
        false
      end
    end

    # Receive inter-agent messages (override in subclasses)
    def receive_message(data, from:)
      logger.debug "Received message from #{from.agent_name}: #{data.inspect}"
    end

    def receive_broadcast(data, from:)
      logger.debug "Received broadcast from #{from.agent_name}: #{data.inspect}"
    end

    # Override event handling to track conversation
    def _handle_message(event)
      # Mark as busy while processing
      mark_busy!

      # Track conversation if we have an agent record
      conversation_memory(event[:sender], event[:room_id])&.add_message(event) if @agent_record && event[:type] == 'm.room.message'

      super
    ensure
      # Mark as idle when done
      mark_idle!
    end

    def _handle_event(event)
      mark_busy!
      super
    ensure
      mark_idle!
    end

    # Enhanced settings with agent-specific overrides
    def settings
      return self.class unless @agent_record

      # Merge agent-specific settings with class settings
      @settings ||= begin
        base_settings = self.class.settings
        agent_settings = @agent_record.settings || {}

        # Create a settings proxy that checks agent settings first
        SettingsProxy.new(base_settings, agent_settings)
      end
    end

    private

    def setup_agent_context
      # Set up agent-specific logging
      if @agent_record
        @logger = ActiveMatrix.logger.dup
        @logger.progname = "[#{@agent_record.name}]"
      end

      # Load any agent-specific configuration
      return unless @agent_record.settings['commands_disabled']

      @agent_record.settings['commands_disabled'].each do |cmd|
        # Temporarily disable commands for this instance
        @disabled_commands ||= []
        @disabled_commands << cmd
      end
    end

    # Settings proxy to merge class and instance settings
    class SettingsProxy
      def initialize(base_settings, agent_settings)
        @base_settings = base_settings
        @agent_settings = agent_settings
      end

      def method_missing(method, *, &)
        method_name = method.to_s.gsub(/\?$/, '')

        # Check agent settings first
        if @agent_settings.key?(method_name)
          value = @agent_settings[method_name]
          return method.to_s.end_with?('?') ? !value.nil? : value
        end

        # Fall back to base settings
        @base_settings.send(method, *, &)
      end

      def respond_to_missing?(method, include_private = false)
        method_name = method.to_s.gsub(/\?$/, '')
        @agent_settings.key?(method_name) || @base_settings.respond_to?(method, include_private)
      end
    end
  end
end
