# frozen_string_literal: true

module ActiveMatrix
  class Daemon
    # Worker process that runs a subset of agents
    #
    # Each worker is a forked child process that:
    # - Initializes its own AgentManager
    # - Runs only assigned agents (by ID)
    # - Handles signals for graceful shutdown
    #
    class Worker
      attr_reader :index, :agent_ids

      def initialize(index:, agent_ids:)
        @index = index
        @agent_ids = agent_ids
        @running = false
      end

      def run
        @running = true

        set_process_name
        install_signal_handlers
        reconnect_database

        logger.info "Worker #{index} starting with agents: #{agent_ids.join(', ')}"

        run_agents
      rescue StandardError => e
        logger.error "Worker #{index} crashed: #{e.message}"
        logger.error e.backtrace.join("\n")
        raise
      ensure
        logger.info "Worker #{index} exiting"
      end

      private

      def set_process_name
        Process.setproctitle("activematrix[#{index}]: #{agent_ids.size} agents")
      end

      def install_signal_handlers
        Signal.trap('TERM') do
          @running = false
          AgentManager.instance.stop_all
        end

        Signal.trap('INT') do
          @running = false
          AgentManager.instance.stop_all
        end

        Signal.trap('HUP') do
          # Reload - restart agents with new config
          logger.info "Worker #{index} received HUP, reloading..."
          # For now, just log. Full reload would require:
          # 1. Stop all agents
          # 2. Re-query DB for agent list
          # 3. Start new agents
        end

        Signal.trap('USR1') do
          # Log rotation
          if $stdout.respond_to?(:path) && $stdout.path
            $stdout.reopen($stdout.path, 'a')
            $stdout.sync = true
          end
          if $stderr.respond_to?(:path) && $stderr.path
            $stderr.reopen($stderr.path, 'a')
            $stderr.sync = true
          end
        end
      end

      def reconnect_database
        # After fork, we need fresh database connections
        ActiveRecord::Base.connection_handler.clear_active_connections!
        ActiveRecord::Base.establish_connection
      end

      def run_agents
        manager = AgentManager.instance

        # Install signal handlers for the manager
        manager.install_signal_handlers!

        # Load only our assigned agents
        agents = ActiveMatrix::Agent.where(id: agent_ids)

        if agents.empty?
          logger.warn "Worker #{index} has no agents to run"
          return
        end

        # Start the manager with only our agents
        Sync do
          manager.start_agents(agents)
        end
      end

      def logger
        ActiveMatrix.logger
      end
    end
  end
end
