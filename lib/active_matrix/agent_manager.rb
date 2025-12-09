# frozen_string_literal: true

require 'singleton'
require 'async'
require 'async/barrier'
require 'async/semaphore'

module ActiveMatrix
  # Manages the lifecycle of Matrix bot agents using async fibers
  class AgentManager
    include Singleton
    include ActiveMatrix::Logging

    attr_reader :registry, :config

    def initialize
      @registry = AgentRegistry.instance
      @config = ActiveMatrix.config
      @barrier = nil
      @monitor_task = nil
      @running = false
    end

    # Install signal handlers for graceful shutdown.
    # Call this explicitly if you want the gem to handle SIGINT/SIGTERM.
    # By default, signal handling is left to the host application.
    def install_signal_handlers!
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          stop_all
          exit # rubocop:disable Rails/Exit
        end
      end
    end

    # Start all agents marked as active in the database
    # This is the main entry point - runs the async reactor
    def start_all
      agents = ActiveMatrix::Agent.where.not(state: :offline)
      start_agents(agents)
    end

    # Start specific agents (used by daemon workers)
    # @param agents [ActiveRecord::Relation, Array<Agent>] Agents to start
    def start_agents(agents)
      return if @running

      @running = true
      agents_array = agents.respond_to?(:to_a) ? agents.to_a : agents
      logger.info "Starting #{agents_array.size} agents..."

      Sync do
        @barrier = Async::Barrier.new

        startup_delay = config.agent_startup_delay || 2

        agents_array.each_with_index do |agent, index|
          sleep(startup_delay) if index.positive?
          start_agent(agent)
        end

        start_monitor_task

        logger.info "Started #{@registry.count} agents"

        # Wait for all agent tasks to complete (blocks until shutdown)
        @barrier.wait
      ensure
        @barrier&.stop
        @running = false
      end
    end

    # Start a specific agent as an async task
    def start_agent(agent)
      return false unless @running

      if @registry.running?(agent)
        logger.warn "Agent #{agent.name} is already running"
        return false
      end

      logger.info "Starting agent: #{agent.name}"

      begin
        agent.connect!

        task = @barrier.async do |subtask|
          subtask.annotate "agent-#{agent.name}"
          run_agent(agent)
        end

        # Store task reference for later control
        @registry.register_task(agent, task)
        true
      rescue StandardError => e
        logger.error "Failed to start agent #{agent.name}: #{e.message}"
        agent.encounter_error!
        false
      end
    end

    # Stop a specific agent
    def stop_agent(agent)
      entry = @registry.get(agent.id)
      return false unless entry

      logger.info "Stopping agent: #{agent.name}"

      begin
        # Stop the client sync
        client = entry[:instance]&.client
        client&.stop_listener if client&.listening?

        # Save sync token
        agent.update(last_sync_token: client.sync_token) if client&.sync_token.present?

        # Stop the async task gracefully
        task = entry[:task]
        task&.stop

        # Update state
        agent.disconnect! if agent.may_disconnect?

        true
      rescue StandardError => e
        logger.error "Error stopping agent #{agent.name}: #{e.message}"
        false
      end
    end

    # Stop all running agents
    def stop_all
      logger.info 'Stopping all agents...'

      # Stop monitor task
      @monitor_task&.stop

      # Stop all agent tasks via barrier
      @barrier&.stop

      @running = false
      logger.info 'All agents stopped'
    end

    # Restart an agent
    def restart_agent(agent)
      stop_agent(agent)
      sleep(1) # Brief pause
      start_agent(agent)
    end

    # Pause an agent (keep it registered but stop processing)
    def pause_agent(agent)
      return false unless agent.may_pause?

      entry = @registry.get(agent.id)
      return false unless entry

      logger.info "Pausing agent: #{agent.name}"

      client = entry[:instance]&.client
      client&.stop_listener if client&.listening?
      agent.pause!

      true
    end

    # Resume a paused agent
    def resume_agent(agent)
      return false unless agent.paused?

      entry = @registry.get(agent.id)
      return false unless entry

      logger.info "Resuming agent: #{agent.name}"

      agent.resume!
      client = entry[:instance]&.client
      client&.start_listener
      agent.connection_established!

      true
    end

    # Get status of all agents
    def status
      {
        running: @registry.count,
        agents: @registry.health_status,
        monitor_active: @monitor_task&.alive? || false,
        shutdown: !@running
      }
    end

    # Check if currently running
    def running?
      @running
    end

    private

    def run_agent(agent)
      # Create client and bot instance
      client = create_client_for_agent(agent)
      bot_class = agent.bot_class.constantize
      bot_instance = bot_class.new(client)

      # Register the agent
      @registry.register(agent, bot_instance)

      # Authenticate if needed
      if agent.access_token.present?
        client.access_token = agent.access_token
      else
        client.login(agent.username, agent.password)
        agent.update(access_token: client.access_token)
      end

      # Restore sync token if available
      client.sync_token = agent.last_sync_token if agent.last_sync_token.present?

      # Mark as online
      agent.connection_established!

      # Run the sync loop (blocks until stopped)
      client.listen_forever
    rescue Async::Stop
      logger.info "Agent #{agent.name} stopping gracefully"
    rescue StandardError => e
      logger.error "Error in agent #{agent.name}: #{e.message}"
      logger.error e.backtrace.first(10).join("\n")
      agent.encounter_error!
      raise
    ensure
      @registry.unregister(agent)
      agent.disconnect! if agent.may_disconnect?
    end

    def create_client_for_agent(agent)
      ClientPool.instance.get_client(agent.homeserver)
    end

    def start_monitor_task
      return if @monitor_task&.alive?

      health_interval = config.agent_health_check_interval || 30

      @monitor_task = Async(transient: true) do |task|
        task.annotate 'agent-monitor'

        loop do
          sleep(health_interval)
          check_agent_health
          cleanup_stale_data
        rescue StandardError => e
          logger.error "Monitor task error: #{e.message}"
        end
      end
    end

    def check_agent_health
      @registry.find_each do |entry|
        agent = entry[:record]
        task = entry[:task]

        # Check if task is alive
        unless task&.alive?
          logger.warn "Agent #{agent.name} task died, restarting..."
          @registry.unregister(agent)
          agent.encounter_error!
          start_agent(agent) if @running
          next
        end

        # Check last activity
        if agent.last_active_at && agent.last_active_at < 5.minutes.ago
          logger.warn "Agent #{agent.name} seems inactive"
        end
      end
    end

    def cleanup_stale_data
      ActiveMatrix::ChatSession.cleanup_stale!
      ActiveMatrix::AgentStore.cleanup_expired!
      ActiveMatrix::KnowledgeBase.cleanup_expired!
    end
  end
end
