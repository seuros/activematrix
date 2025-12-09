# frozen_string_literal: true

# rubocop:disable Rails/Exit
require 'thor'
require 'active_matrix'
require 'active_matrix/daemon'

module ActiveMatrix
  # Command-line interface for ActiveMatrix daemon
  #
  # @example Start the daemon
  #   bundle exec activematrix start
  #
  # @example Start with options
  #   bundle exec activematrix start --workers 3 --probe-port 3042
  #
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc 'start', 'Start the ActiveMatrix daemon'
    option :workers, type: :numeric, default: 1, desc: 'Number of worker processes'
    option :probe_port, type: :numeric, default: 3042, desc: 'Health check probe port'
    option :probe_host, type: :string, default: '127.0.0.1', desc: 'Health check bind address'
    option :agents, type: :string, desc: 'Comma-separated list of agent names to start'
    option :daemon, type: :boolean, default: false, desc: 'Run as background daemon'
    option :pidfile, type: :string, desc: 'PID file path (implies --daemon)'
    option :logfile, type: :string, desc: 'Log file path'
    option :require, type: :string, aliases: '-r', desc: 'File to require before starting'
    option :environment, type: :string, aliases: '-e', desc: 'Rails environment'
    def start
      boot_rails
      configure_from_options

      daemonize if options[:daemon] || options[:pidfile]

      run_daemon
    end

    desc 'stop', 'Stop the ActiveMatrix daemon'
    option :pidfile, type: :string, default: 'tmp/pids/activematrix.pid', desc: 'PID file path'
    option :timeout, type: :numeric, default: 30, desc: 'Shutdown timeout in seconds'
    def stop
      pidfile = options[:pidfile]

      unless File.exist?(pidfile)
        say "PID file not found: #{pidfile}", :red
        exit 1
      end

      pid = File.read(pidfile).to_i
      say "Stopping ActiveMatrix daemon (PID: #{pid})..."

      begin
        Process.kill('TERM', pid)
        wait_for_shutdown(pid, options[:timeout])
        say 'Daemon stopped successfully', :green
      rescue Errno::ESRCH
        say 'Process not running, cleaning up PID file', :yellow
        File.delete(pidfile)
      rescue Errno::EPERM
        say "Permission denied to stop process #{pid}", :red
        exit 1
      end
    end

    desc 'status', 'Show daemon status'
    option :pidfile, type: :string, default: 'tmp/pids/activematrix.pid', desc: 'PID file path'
    option :probe_port, type: :numeric, default: 3042, desc: 'Health check probe port'
    option :probe_host, type: :string, default: '127.0.0.1', desc: 'Health check host'
    def status
      # Try HTTP probe first
      if (probe_status = fetch_probe_status)
        display_status(probe_status)
      elsif (pid = read_pid)
        say "Daemon running (PID: #{pid}), but health probe not responding", :yellow
      else
        say 'Daemon not running', :red
        exit 1
      end
    end

    desc 'reload', 'Reload agent configuration'
    option :pidfile, type: :string, default: 'tmp/pids/activematrix.pid', desc: 'PID file path'
    def reload
      pid = read_pid
      unless pid
        say 'Daemon not running', :red
        exit 1
      end

      begin
        Process.kill('HUP', pid)
        say 'Reload signal sent', :green
      rescue Errno::ESRCH
        say 'Process not running', :red
        exit 1
      rescue Errno::EPERM
        say 'Permission denied', :red
        exit 1
      end
    end

    desc 'version', 'Show ActiveMatrix version'
    def version
      say "ActiveMatrix #{ActiveMatrix::VERSION}"
    end

    map %w[-v --version] => :version

    private

    def boot_rails
      ENV['RAILS_ENV'] ||= options[:environment] || 'development'

      if options[:require]
        require File.expand_path(options[:require])
      elsif File.exist?('config/environment.rb')
        require File.expand_path('config/environment.rb')
      else
        say 'No Rails application found. Use --require to specify a file.', :red
        exit 1
      end
    end

    def configure_from_options
      ActiveMatrix.configure do |config|
        config.daemon_workers = options[:workers] if options[:workers]
        config.probe_port = options[:probe_port] if options[:probe_port]
        config.probe_host = options[:probe_host] if options[:probe_host]
      end
    end

    def daemonize
      pidfile = options[:pidfile] || 'tmp/pids/activematrix.pid'
      logfile = options[:logfile] || 'log/activematrix.log'

      # Ensure directories exist
      FileUtils.mkdir_p(File.dirname(pidfile))
      FileUtils.mkdir_p(File.dirname(logfile))

      # Check if already running
      if File.exist?(pidfile)
        pid = File.read(pidfile).to_i
        begin
          Process.kill(0, pid)
          say "Daemon already running (PID: #{pid})", :red
          exit 1
        rescue Errno::ESRCH
          File.delete(pidfile)
        end
      end

      Process.daemon(true, true)

      # Redirect output
      $stdout.reopen(logfile, 'a')
      $stderr.reopen($stdout)
      $stdout.sync = true

      # Write PID file
      File.write(pidfile, Process.pid.to_s)

      at_exit { FileUtils.rm_f(pidfile) }
    end

    def run_daemon
      daemon = ActiveMatrix::Daemon.new(
        workers: options[:workers],
        probe_port: options[:probe_port],
        probe_host: options[:probe_host],
        agent_names: parse_agent_names
      )

      daemon.run
    end

    def parse_agent_names
      return nil unless options[:agents]

      options[:agents].split(',').map(&:strip)
    end

    def read_pid
      pidfile = options[:pidfile]
      return nil unless File.exist?(pidfile)

      pid = File.read(pidfile).to_i
      begin
        Process.kill(0, pid)
        pid
      rescue Errno::ESRCH
        nil
      end
    end

    def wait_for_shutdown(pid, timeout)
      deadline = Time.zone.now + timeout

      while Time.zone.now < deadline
        begin
          Process.kill(0, pid)
          sleep 0.5
        rescue Errno::ESRCH
          return true
        end
      end

      say 'Timeout waiting for graceful shutdown, sending SIGKILL', :yellow
      Process.kill('KILL', pid)
    end

    def fetch_probe_status
      require 'net/http'
      require 'json'

      uri = URI("http://#{options[:probe_host]}:#{options[:probe_port]}/status")
      response = Net::HTTP.get_response(uri)

      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body, symbolize_names: true)
    rescue StandardError
      nil
    end

    def display_status(status)
      say 'ActiveMatrix Daemon Status', :green
      say '=' * 40
      say "Status: #{status[:status]}"
      say "Uptime: #{format_duration(status[:uptime])}"
      say "Workers: #{status[:workers]}"
      say ''
      say 'Agents:'
      say "  Total:      #{status.dig(:agents, :total) || 0}"
      say "  Online:     #{status.dig(:agents, :online) || 0}"
      say "  Connecting: #{status.dig(:agents, :connecting) || 0}"
      say "  Error:      #{status.dig(:agents, :error) || 0}"
    end

    def format_duration(seconds)
      return 'N/A' unless seconds

      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      secs = seconds % 60

      if hours.positive?
        "#{hours}h #{minutes}m #{secs}s"
      elsif minutes.positive?
        "#{minutes}m #{secs}s"
      else
        "#{secs}s"
      end
    end
  end
end
# rubocop:enable Rails/Exit
