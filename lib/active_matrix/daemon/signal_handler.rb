# frozen_string_literal: true

module ActiveMatrix
  class Daemon
    # Handles Unix signals for the daemon coordinator
    #
    # Signals:
    # - TERM/INT: Graceful shutdown
    # - HUP: Reload configuration and restart agents
    # - USR1: Log rotation (reopen log files)
    # - USR2: Dump debug information
    #
    class SignalHandler
      SIGNALS = %w[TERM INT HUP USR1 USR2].freeze

      attr_reader :daemon

      def initialize(daemon)
        @daemon = daemon
        @self_pipe_reader, @self_pipe_writer = IO.pipe
        @old_handlers = {}
      end

      def install
        SIGNALS.each do |signal|
          install_handler(signal)
        end

        # Start signal processing thread
        start_processor
      end

      def uninstall
        SIGNALS.each do |signal|
          restore_handler(signal)
        end

        @self_pipe_writer.close
        @self_pipe_reader.close
      end

      private

      def install_handler(signal)
        @old_handlers[signal] = Signal.trap(signal) do
          # Write signal to pipe (non-blocking, safe in signal handler)
          @self_pipe_writer.write_nonblock("#{signal}\n")
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          # Pipe full, signal will be coalesced
        end
      rescue ArgumentError
        # Signal not supported on this platform
        logger.debug "Signal #{signal} not supported"
      end

      def restore_handler(signal)
        return unless @old_handlers.key?(signal)

        Signal.trap(signal, @old_handlers[signal])
      end

      def start_processor
        Thread.new do
          Thread.current.name = 'activematrix-signal-processor'

          loop do
            # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler
            ready = IO.select([@self_pipe_reader], nil, nil, 1)
            # rubocop:enable Lint/IncompatibleIoSelectWithFiberScheduler
            next unless ready

            signal = @self_pipe_reader.gets&.strip
            next unless signal

            handle_signal(signal)
          rescue IOError
            break
          end
        end
      end

      def handle_signal(signal)
        logger.info "Received signal: #{signal}"

        case signal
        when 'TERM', 'INT'
          handle_shutdown
        when 'HUP'
          handle_reload
        when 'USR1'
          handle_log_rotation
        when 'USR2'
          handle_debug_dump
        end
      end

      def handle_shutdown
        logger.info 'Initiating graceful shutdown...'
        daemon.shutdown
      end

      def handle_reload
        logger.info 'Reloading agent configuration...'
        # TODO: Implement reload
        # 1. Query for new/removed agents
        # 2. Send HUP to workers for them to reload
        daemon.worker_pids.each do |pid|
          Process.kill('HUP', pid)
        rescue Errno::ESRCH
          # Worker already dead
        end
      end

      def handle_log_rotation
        logger.info 'Rotating log files...'

        # Reopen stdout/stderr if they're files
        if $stdout.respond_to?(:path) && $stdout.path
          $stdout.reopen($stdout.path, 'a')
          $stdout.sync = true
        end

        if $stderr.respond_to?(:path) && $stderr.path
          $stderr.reopen($stderr.path, 'a')
          $stderr.sync = true
        end

        # Signal workers to rotate their logs too
        daemon.worker_pids.each do |pid|
          Process.kill('USR1', pid)
        rescue Errno::ESRCH
          # Worker already dead
        end
      end

      def handle_debug_dump
        logger.info 'Dumping debug information...'

        # Dump current state
        status = daemon.status
        logger.info "Status: #{status.inspect}"

        # Dump thread backtraces
        Thread.list.each do |thread|
          logger.info "Thread: #{thread.name || thread.object_id}"
          logger.info thread.backtrace&.join("\n") || '(no backtrace)'
          logger.info '---'
        end
      end

      def logger
        ActiveMatrix.logger
      end
    end
  end
end
