# frozen_string_literal: true

require 'singleton'
require 'concurrent'

module ActiveMatrix
  # Thread-safe registry for managing running bot agents
  class AgentRegistry
    include Singleton
    include ActiveMatrix::Logging

    def initialize
      @agents = Concurrent::Hash.new
      @mutex = Mutex.new
    end

    # Register a running agent
    def register(agent_record, bot_instance)
      @mutex.synchronize do
        raise AgentAlreadyRunningError, "Agent #{agent_record.name} is already running" if @agents.key?(agent_record.id)

        @agents[agent_record.id] = {
          record: agent_record,
          instance: bot_instance,
          thread: Thread.current,
          started_at: Time.current
        }

        logger.info "Registered agent: #{agent_record.name} (#{agent_record.id})"
      end
    end

    # Unregister an agent
    def unregister(agent_record)
      @mutex.synchronize do
        entry = @agents.delete(agent_record.id)
        logger.info "Unregistered agent: #{agent_record.name} (#{agent_record.id})" if entry
        entry
      end
    end

    # Get a running agent by ID
    def get(agent_id)
      @agents[agent_id]
    end

    # Get agent by name
    def get_by_name(name)
      @agents.values.find { |entry| entry[:record].name == name }
    end

    # Get all running agents
    def all
      @agents.values
    end

    # Get all agent records
    def all_records
      @agents.values.map { |entry| entry[:record] }
    end

    # Get all bot instances
    def all_instances
      @agents.values.map { |entry| entry[:instance] }
    end

    # Check if an agent is running
    def running?(agent_record)
      @agents.key?(agent_record.id)
    end

    # Get agents by state
    def by_state(state)
      @agents.values.select { |entry| entry[:record].state == state.to_s }
    end

    # Get agents by bot class
    def by_class(bot_class)
      class_name = bot_class.is_a?(Class) ? bot_class.name : bot_class.to_s
      @agents.values.select { |entry| entry[:record].bot_class == class_name }
    end

    # Get agents by homeserver
    def by_homeserver(homeserver)
      @agents.values.select { |entry| entry[:record].homeserver == homeserver }
    end

    # Broadcast to all agents
    def broadcast
      all_instances.each do |instance|
        yield instance
      rescue StandardError => e
        logger.error "Error broadcasting to agent: #{e.message}"
      end
    end

    # Broadcast to specific agents
    def broadcast_to(selector)
      agents = case selector
               when Symbol
                 by_state(selector)
               when String
                 by_name_pattern(selector)
               when Class
                 by_class(selector)
               when Proc
                 @agents.values.select { |entry| selector.call(entry[:record]) }
               else
                 []
               end

      agents.each do |entry|
        yield entry[:instance]
      rescue StandardError => e
        logger.error "Error broadcasting to agent #{entry[:record].name}: #{e.message}"
      end
    end

    # Get count of running agents
    def count
      @agents.size
    end

    # Clear all agents (used for testing)
    def clear!
      @mutex.synchronize do
        @agents.clear
      end
    end

    # Get health status of all agents
    def health_status
      @agents.map do |id, entry|
        {
          id: id,
          name: entry[:record].name,
          state: entry[:record].state,
          thread_alive: entry[:thread]&.alive?,
          uptime: Time.current - entry[:started_at],
          last_active: entry[:record].last_active_at
        }
      end
    end

    private

    def by_name_pattern(pattern)
      regex = Regexp.new(pattern, Regexp::IGNORECASE)
      @agents.values.select { |entry| entry[:record].name =~ regex }
    end
  end

  class AgentAlreadyRunningError < StandardError; end
end
