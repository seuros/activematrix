# frozen_string_literal: true

module ActiveMatrix
  class Agent < ApplicationRecord
    module Jobs
      # Background job responsible for harvesting dead agent memories from the system.
      #
      # This job systematically harvests dead memory entries to prevent database bloat
      # and maintain optimal performance. It operates as a scheduled reaper process
      # that runs automatically when agent memories reach their expiration time.
      #
      # The job performs the following operations:
      # 1. Identifies dead agent memory records based on their expires_at timestamp
      # 2. Harvests dead entries from both database and cache layers
      # 3. Logs harvesting statistics for monitoring and debugging purposes
      # 4. Handles harvesting failures gracefully without affecting system stability
      #
      # Usage:
      #   # Schedule immediate harvesting
      #   ActiveMatrix::Agent::Jobs::MemoryReaper.perform_later
      #
      #   # Schedule harvesting for specific time
      #   ActiveMatrix::Agent::Jobs::MemoryReaper.set(wait_until: 1.hour.from_now).perform_later
      #
      class MemoryReaper < ActiveMatrix::ApplicationJob
        queue_as :maintenance

        # Performs the memory reaping operation with comprehensive error handling
        def perform
          ActiveMatrix.logger.info 'Starting agent memory reaping operation'

          reaping_stats = {
            agent_memories_reaped: 0,
            cache_entries_cleared: 0,
            errors_encountered: 0
          }

          begin
            # Harvest dead agent memories
            reaping_stats[:agent_memories_reaped] = harvest_dead_agent_memories

            # Clear associated cache entries
            reaping_stats[:cache_entries_cleared] = clear_expired_cache_entries

            ActiveMatrix.logger.info "Memory reaping completed successfully: #{reaping_stats}"
          rescue StandardError => e
            reaping_stats[:errors_encountered] += 1
            ActiveMatrix.logger.error "Memory reaping failed: #{e.message}"
            ActiveMatrix.logger.error e.backtrace.join("\n")

            # Re-raise to ensure job is marked as failed for retry
            raise e
          end

          reaping_stats
        end

        private

        # Harvests dead agent memory records from the database
        # Returns the number of records harvested
        def harvest_dead_agent_memories
          return 0 unless defined?(ActiveMatrix::AgentStore)

          dead_memories = ActiveMatrix::AgentStore.expired
          count = dead_memories.count

          if count.positive?
            ActiveMatrix.logger.debug "Harvesting #{count} dead agent memory records"
            dead_memories.destroy_all
          end

          count
        end

        # Clears expired memory entries from the Rails cache
        # Returns the number of cache entries cleared
        def clear_expired_cache_entries
          # NOTE: Rails.cache doesn't provide a direct way to clear expired entries
          # This is a placeholder for cache-specific cleanup logic if needed
          # Most cache stores handle expiration automatically
          0
        end
      end
    end
  end
end
