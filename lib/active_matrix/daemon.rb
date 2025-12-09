# frozen_string_literal: true

require_relative 'daemon/signal_handler'
require_relative 'daemon/probe_server'
require_relative 'daemon/worker'
require_relative 'telemetry'

module ActiveMatrix
  # Main daemon coordinator for managing Matrix bot agents
  #
  # Responsibilities:
  # - Fork and manage worker processes
  # - Distribute agents across workers
  # - Handle signals (TERM, INT, HUP, USR1, USR2)
  # - Run HTTP health probe server
  # - Monitor worker health and restart on crash
  #
  class Daemon
    attr_reader :workers_count, :probe_port, :probe_host, :agent_names, :worker_pids, :start_time

    def initialize(workers: 1, probe_port: 3042, probe_host: '127.0.0.1', agent_names: nil)
      @workers_count = workers
      @probe_port = probe_port
      @probe_host = probe_host
      @agent_names = agent_names
      @worker_pids = []
      @running = false
      @start_time = nil
    end

    def run
      @start_time = Time.zone.now
      @running = true

      logger.info "Starting ActiveMatrix daemon (workers: #{workers_count}, probe: #{probe_host}:#{probe_port})"

      # Initialize OpenTelemetry if available
      logger.info 'OpenTelemetry tracing enabled' if Telemetry.configure!

      install_signal_handlers
      start_probe_server
      start_workers

      monitor_loop
    ensure
      shutdown
    end

    def shutdown
      return unless @running

      @running = false
      logger.info 'Shutting down ActiveMatrix daemon...'

      stop_probe_server
      stop_workers

      Telemetry.shutdown

      logger.info 'ActiveMatrix daemon stopped'
    end

    def status
      {
        status: @running ? 'ok' : 'stopping',
        uptime: @start_time ? (Time.zone.now - @start_time).to_i : 0,
        workers: worker_pids.size,
        agents: aggregate_agent_status
      }
    end

    private

    def logger
      ActiveMatrix.logger
    end

    def install_signal_handlers
      @signal_handler = SignalHandler.new(self)
      @signal_handler.install
    end

    def start_probe_server
      @probe_server = ProbeServer.new(
        host: probe_host,
        port: probe_port,
        daemon: self
      )
      @probe_server.start
    end

    def stop_probe_server
      @probe_server&.stop
    end

    def start_workers
      agents = load_agents
      agent_groups = distribute_agents(agents, workers_count)

      agent_groups.each_with_index do |agent_ids, index|
        next if agent_ids.empty?

        pid = fork_worker(index, agent_ids)
        worker_pids << pid
        logger.info "Started worker #{index} (PID: #{pid}) with #{agent_ids.size} agents"
      end
    end

    def fork_worker(index, agent_ids)
      fork do
        # Reset signal handlers in child
        Signal.trap('TERM') { exit } # rubocop:disable Rails/Exit
        Signal.trap('INT') { exit } # rubocop:disable Rails/Exit

        # Close parent's probe server socket
        @probe_server&.stop

        # Run worker
        worker = Worker.new(index: index, agent_ids: agent_ids)
        worker.run
      end
    end

    def stop_workers
      timeout = ActiveMatrix.config.shutdown_timeout || 30

      # Send TERM to all workers
      worker_pids.each do |pid|
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        # Already dead
      end

      # Wait for graceful shutdown
      deadline = Time.zone.now + timeout
      while worker_pids.any? && Time.zone.now < deadline
        worker_pids.reject! do |pid|
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          true
        end
        sleep 0.5 if worker_pids.any?
      end

      # Force kill remaining
      worker_pids.each do |pid|
        logger.warn "Force killing worker #{pid}"
        Process.kill('KILL', pid)
        Process.waitpid(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # Already dead
      end

      worker_pids.clear
    end

    def monitor_loop
      while @running
        # Reap dead children
        reap_workers

        # Restart crashed workers
        restart_crashed_workers if @running

        sleep 1
      end
    end

    def reap_workers
      loop do
        pid = Process.waitpid(-1, Process::WNOHANG)
        break unless pid

        if worker_pids.include?(pid)
          logger.warn "Worker #{pid} exited"
          worker_pids.delete(pid)
        end
      rescue Errno::ECHILD
        break
      end
    end

    def restart_crashed_workers
      return if worker_pids.size >= workers_count

      # Determine which agents are orphaned
      worker_pids.size * (load_agents.size / workers_count.to_f).ceil
      # For simplicity, just spawn new workers to fill the gap
      while worker_pids.size < workers_count && @running
        agents = load_agents
        agent_groups = distribute_agents(agents, workers_count)
        index = worker_pids.size

        next if agent_groups[index].blank?

        pid = fork_worker(index, agent_groups[index])
        worker_pids << pid
        logger.info "Restarted worker #{index} (PID: #{pid})"
      end
    end

    def load_agents
      scope = ActiveMatrix::Agent.where.not(state: :offline)
      scope = scope.where(name: agent_names) if agent_names.present?
      scope.pluck(:id)
    end

    def distribute_agents(agent_ids, num_workers)
      return [agent_ids] if num_workers <= 1

      # Round-robin distribution
      groups = Array.new(num_workers) { [] }
      agent_ids.each_with_index do |id, index|
        groups[index % num_workers] << id
      end
      groups
    end

    def aggregate_agent_status
      # In multi-process mode, we'd need IPC to get real status
      # For now, query the database
      agents = ActiveMatrix::Agent.all

      {
        total: agents.count,
        online: agents.where(state: %i[online_idle online_busy]).count,
        connecting: agents.where(state: :connecting).count,
        error: agents.where(state: :error).count,
        offline: agents.where(state: :offline).count
      }
    end
  end
end
