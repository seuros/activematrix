# frozen_string_literal: true

module ActiveMatrix
  module Memory
    # Per-agent private memory storage
    class AgentMemory < Base
      attr_reader :agent

      def initialize(agent)
        super()
        @agent = agent
      end

      # Get a value from agent memory
      def get(key)
        fetch_with_cache(key) do
          return nil unless defined?(::AgentMemory)

          memory = @agent.agent_memories.active.find_by(key: key)
          memory&.value
        end
      end

      # Set a value in agent memory
      def set(key, value, expires_in: nil)
        return false unless defined?(::AgentMemory)

        write_through(key, value, expires_in: expires_in) do
          memory = @agent.agent_memories.find_or_initialize_by(key: key)
          memory.value = value
          memory.expires_at = expires_in.present? ? Time.current + expires_in : nil
          memory.save!
        end
      end

      # Check if a key exists
      def exists?(key)
        return false unless defined?(::AgentMemory)

        if @cache_enabled && Rails.cache.exist?(cache_key(key))
          true
        else
          @agent.agent_memories.active.exists?(key: key)
        end
      end

      # Delete a key
      def delete(key)
        return false unless defined?(::AgentMemory)

        delete_through(key) do
          @agent.agent_memories.where(key: key).destroy_all.any?
        end
      end

      # Get all keys
      def keys
        return [] unless defined?(::AgentMemory)

        @agent.agent_memories.active.pluck(:key)
      end

      # Get all memory as hash
      def all
        return {} unless defined?(::AgentMemory)

        @agent.agent_memories.active.pluck(:key, :value).to_h
      end

      # Clear all agent memory
      def clear!
        return false unless defined?(::AgentMemory)

        @agent.agent_memories.destroy_all

        # Clear cache entries
        keys.each { |key| Rails.cache.delete(cache_key(key)) } if @cache_enabled

        true
      end

      # Remember something with optional TTL
      def remember(key, expires_in: nil)
        value = get(key)
        return value if value.present?

        value = yield
        set(key, value, expires_in: expires_in) if value.present?
        value
      end

      # Increment a counter
      def increment(key, amount = 1)
        current = get(key) || 0
        new_value = current + amount
        set(key, new_value)
        new_value
      end

      # Decrement a counter
      def decrement(key, amount = 1)
        increment(key, -amount)
      end

      # Add to a list
      def push(key, value)
        list = get(key) || []
        list << value
        set(key, list)
        list
      end

      # Remove from a list
      def pull(key, value)
        list = get(key) || []
        list.delete(value)
        set(key, list)
        list
      end

      protected

      def cache_key(key)
        "agent_memory/#{@agent.id}/#{key}"
      end
    end
  end
end
