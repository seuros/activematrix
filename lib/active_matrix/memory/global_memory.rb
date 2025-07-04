# frozen_string_literal: true

require 'singleton'

module ActiveMatrix
  module Memory
    # Global memory storage accessible to all agents
    class GlobalMemory < Base
      include Singleton

      # Get a value from global memory
      def get(key)
        fetch_with_cache(key) do
          return nil unless defined?(::GlobalMemory)

          ::GlobalMemory.get(key)
        end
      end

      # Set a value in global memory
      def set(key, value, category: nil, expires_in: nil, public_read: true, public_write: false)
        return false unless defined?(::GlobalMemory)

        write_through(key, value, expires_in: expires_in) do
          ::GlobalMemory.set(key, value,
                             category: category,
                             expires_in: expires_in,
                             public_read: public_read,
                             public_write: public_write)
        end
      end

      # Check if a key exists
      def exists?(key)
        return false unless defined?(::GlobalMemory)

        if @cache_enabled && Rails.cache.exist?(cache_key(key))
          true
        else
          ::GlobalMemory.active.exists?(key: key)
        end
      end

      # Delete a key
      def delete(key)
        return false unless defined?(::GlobalMemory)

        delete_through(key) do
          ::GlobalMemory.where(key: key).destroy_all.any?
        end
      end

      # Get all keys in a category
      def keys(category: nil)
        return [] unless defined?(::GlobalMemory)

        scope = ::GlobalMemory.active
        scope = scope.by_category(category) if category
        scope.pluck(:key)
      end

      # Get all values in a category
      def by_category(category)
        return {} unless defined?(::GlobalMemory)

        ::GlobalMemory.active.by_category(category).pluck(:key, :value).to_h
      end

      # Check if readable by agent
      def readable?(key, agent = nil)
        return false unless defined?(::GlobalMemory)

        memory = ::GlobalMemory.find_by(key: key)
        memory&.readable_by?(agent)
      end

      # Check if writable by agent
      def writable?(key, agent = nil)
        return false unless defined?(::GlobalMemory)

        memory = ::GlobalMemory.find_by(key: key)
        memory&.writable_by?(agent)
      end

      # Get with permission check
      def get_for_agent(key, agent)
        return nil unless readable?(key, agent)

        get(key)
      end

      # Set with permission check
      def set_for_agent(key, value, agent, **)
        # Allow creating new keys or updating writable ones
        memory = ::GlobalMemory.find_by(key: key)
        return false if memory && !memory.writable_by?(agent)

        set(key, value, **)
      end

      # Remember something globally
      def remember(key, **)
        value = get(key)
        return value if value.present?

        value = yield
        set(key, value, **) if value.present?
        value
      end

      # Broadcast a value to all agents
      def broadcast(key, value, expires_in: 5.minutes)
        set(key, value, category: 'broadcast', expires_in: expires_in, public_read: true)

        # Notify all agents if event router is available
        if defined?(EventRouter)
          EventRouter.instance.broadcast_event({
                                                 type: 'global_memory.broadcast',
                                                 key: key,
                                                 value: value
                                               })
        end

        true
      end

      # Share data between specific agents
      def share(key, value, agent_names, expires_in: nil)
        set(key, {
              value: value,
              allowed_agents: agent_names
            }, category: 'shared', expires_in: expires_in, public_read: false)
      end

      # Get shared data if allowed
      def get_shared(key, agent)
        data = get(key)
        return nil unless data.is_a?(Hash) && data['allowed_agents']

        allowed = data['allowed_agents']
        return unless allowed.include?(agent.name) || allowed.include?('*')

        data['value']
      end

      protected

      def cache_key(key)
        "global/#{key}"
      end
    end
  end
end
