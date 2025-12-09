# frozen_string_literal: true

require 'singleton'

module ActiveMatrix
  # Manages the lifecycle of Matrix bot agents
  class AgentManager
    include Singleton
    include ActiveMatrix::Logging

    attr_reader :registry, :config

    def initialize
      @registry = AgentRegistry.instance
      @config = ActiveMatrix.config
      @shutdown = Concurrent::AtomicBoolean.new(false)
      @monitor_thread = nil
    end

    # Install signal handlers for graceful shutdown.
    # Call this explicitly if you want the gem to handle SIGINT/SIGTERM.
    # By default, signal handling is left to the host application.
    def install_signal_handlers!
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          Thread.new { stop_all }.join
          exit # rubocop:disable Rails/Exit
        end
      end
    end

    # Start all agents marked as active in the database
    def start_all
      return if @shutdown.true?

      logger.info 'Starting all active agents...'

      agents = defined?(MatrixAgent) ? MatrixAgent.where.not(state: :offline) : []
      agents.each_with_index do |agent, index|
        sleep(config.agent_startup_delay || 2) if index.positive?
        start_agent(agent)
      end

      start_monitor_thread
      logger.info "Started #{@registry.count} agents"
    end

    # Start a specific agent
    def start_agent(agent)
      return if @shutdown.true?

      if @registry.running?(agent)
        logger.warn "Agent #{agent.name} is already running"
        return false
      end

      logger.info "Starting agent: #{agent.name}"

      begin
        # Update state
        agent.connect!

        # Create bot instance in a new thread
        thread = Thread.new do
          Thread.current.name = "agent-#{agent.name}"

          wrap_with_executor do
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

            # Start the sync loop
            client.start_listener_thread
            client.sync_thread&.join
          rescue Interrupt
            logger.info "Agent #{agent.name} received shutdown signal"
          rescue StandardError => e
            logger.error "Error in agent #{agent.name}: #{e.message}"
            logger.error e.backtrace.join("\n")
            agent.encounter_error!
            raise
          ensure
            @registry.unregister(agent)
            agent.disconnect! if agent.may_disconnect?
          end
        end

        thread.abort_on_exception = true
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
        client = entry[:instance].client
        client.stop_listener_thread if client.listening?

        # Save sync token
        agent.update(last_sync_token: client.sync_token) if client.sync_token.present?

        # Wait for thread to finish gracefully
        thread = entry[:thread]
        if thread&.alive?
          thread.raise(Interrupt) # Signal thread to stop
          thread.join(5) # Wait up to 5 seconds
        end

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
      @shutdown.make_true

      # Stop monitor thread gracefully
      @monitor_thread&.wakeup rescue nil # Wake from sleep

      # Stop all agents
      @registry.all_records.each do |agent|
        stop_agent(agent)
      end

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

      client = entry[:instance].client
      client.stop_listener_thread if client.listening?
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
      client = entry[:instance].client
      client.start_listener_thread
      agent.connection_established!

      true
    end

    # Get status of all agents
    def status
      {
        running: @registry.count,
        agents: @registry.health_status,
        monitor_active: @monitor_thread&.alive? || false,
        shutdown: @shutdown.true?
      }
    end

    private

    def create_client_for_agent(agent)
      # Use shared client pool if available
      if defined?(ClientPool)
        ClientPool.instance.get_client(agent.homeserver)
      else
        ActiveMatrix::Client.new(agent.homeserver,
                                 client_cache: :some,
                                 sync_filter_limit: 20)
      end
    end

    def start_monitor_thread
      return if @monitor_thread&.alive?

      @monitor_thread = Thread.new do
        Thread.current.name = 'agent-monitor'

        loop do
          break if @shutdown.true?

          wrap_with_executor do
            check_agent_health
            cleanup_stale_data
          rescue StandardError => e
            logger.error "Monitor thread error: #{e.message}"
          end

          sleep(config.agent_health_check_interval || 30)
        end
      end
    end

    def check_agent_health
      @registry.find_each do |entry|
        agent = entry[:record]
        thread = entry[:thread]

        # Check if thread is alive
        unless thread&.alive?
          logger.warn "Agent #{agent.name} thread died, restarting..."
          @registry.unregister(agent)
          agent.encounter_error!
          start_agent(agent) unless @shutdown.true?
          next
        end

        # Check last activity
        if agent.last_active_at && agent.last_active_at < 5.minutes.ago
          logger.warn "Agent #{agent.name} seems inactive"
          # Could implement additional health checks here
        end
      end
    end

    def cleanup_stale_data
      # Clean up old conversation contexts
      ConversationContext.cleanup_stale! if defined?(ConversationContext)

      # Clean up expired memories
      AgentMemory.cleanup_expired! if defined?(AgentMemory)
      GlobalMemory.cleanup_expired! if defined?(GlobalMemory)
    end

    # Wraps block with Rails executor if available.
    # This ensures proper connection handling and prevents leaks.
    def wrap_with_executor(&block)
      if defined?(Rails) && Rails.application&.executor
        Rails.application.executor.wrap(&block)
      else
        yield
      end
    end
  end
end
