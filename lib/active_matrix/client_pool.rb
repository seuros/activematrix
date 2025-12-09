# frozen_string_literal: true

require 'singleton'
require 'async'
require 'async/semaphore'
require 'async/condition'

module ActiveMatrix
  # Manages a pool of Matrix client connections for efficiency
  class ClientPool
    include Singleton
    include ActiveMatrix::Logging

    def initialize
      @pools = {}
      @config = ActiveMatrix.config
      @mutex = Mutex.new
    end

    # Get or create a client for a homeserver
    def get_client(homeserver, **)
      pool = @mutex.synchronize { get_or_create_pool(homeserver) }
      pool.checkout(**)
    end

    # Return a client to the pool
    def checkin(client)
      homeserver = client.homeserver
      pool = @pools[homeserver]
      pool&.checkin(client)
    end

    # Get pool statistics
    def stats
      @pools.map do |homeserver, pool|
        {
          homeserver: homeserver,
          size: pool.size,
          available: pool.available_count,
          in_use: pool.in_use_count
        }
      end
    end

    # Clear all pools
    def clear!
      @mutex.synchronize do
        @pools.each_value(&:clear!)
        @pools.clear
      end
    end

    # Shutdown all pools
    def shutdown
      clear!
    end

    private

    def get_or_create_pool(homeserver)
      @pools[homeserver] ||= HomeserverPool.new(
        homeserver,
        max_size: @config&.max_clients_per_homeserver || 5,
        timeout: @config&.client_idle_timeout || 5.minutes
      )
    end

    # Pool for a specific homeserver
    class HomeserverPool
      include ActiveMatrix::Logging

      attr_reader :homeserver, :max_size, :timeout

      def initialize(homeserver, max_size:, timeout:)
        @homeserver = homeserver
        @max_size = max_size
        @timeout = timeout
        @available = []
        @in_use = {}
        @mutex = Mutex.new
        @semaphore = Async::Semaphore.new(max_size)
      end

      def checkout(**)
        # Acquire from semaphore (blocks if pool is exhausted)
        @semaphore.acquire

        @mutex.synchronize do
          # Try to find an available client
          client = find_available_client

          # Create new client if needed
          client = create_client(**) if client.nil?

          # Mark as in use
          @available.delete(client)
          @in_use[client.object_id] = {
            client: client,
            checked_out_at: Time.current
          }

          client
        end
      end

      def checkin(client)
        @mutex.synchronize do
          entry = @in_use.delete(client.object_id)
          return unless entry

          # Add back to available pool if still valid
          if client_valid?(client)
            @available << client
          else
            # Client is no longer valid, don't return to pool
            logger.debug "Discarding invalid client for #{@homeserver}"
          end
        end

        # Release semaphore slot
        @semaphore.release
      end

      def size
        @mutex.synchronize { @available.size + @in_use.size }
      end

      def available_count
        @mutex.synchronize { @available.size }
      end

      def in_use_count
        @mutex.synchronize { @in_use.size }
      end

      def clear!
        @mutex.synchronize do
          # Stop all clients
          (@available + @in_use.values.map { |e| e[:client] }).each do |client|
            client.stop_listener if client.listening?
            client.logout if client.logged_in?
          rescue StandardError => e
            logger.error "Error cleaning up client: #{e.message}"
          end

          @available.clear
          @in_use.clear
        end
      end

      private

      def find_available_client
        # Remove any expired clients
        @available.select! { |client| client_valid?(client) }

        # Return first available
        @available.shift
      end

      def create_client(**)
        logger.debug "Creating new client for #{@homeserver}"

        ActiveMatrix::Client.new(
          @homeserver,
          client_cache: :some,
          sync_filter_limit: 20,
          **
        )
      end

      def client_valid?(client)
        # Check if client is still connected and responsive
        return false unless client

        # Could add more validation here
        true
      rescue StandardError
        false
      end
    end
  end

  # Monkey patch Client to support pooling
  class Client
    # Checkin this client back to the pool
    def checkin_to_pool
      ClientPool.instance.checkin(self) if defined?(ClientPool)
    end
  end
end
