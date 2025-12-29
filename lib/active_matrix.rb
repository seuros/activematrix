# frozen_string_literal: true

# Version is required for gem specification
require_relative 'active_matrix/version'

require 'json'
require 'zeitwerk'
require 'active_record'
require 'active_job'
require 'state_machines-activerecord'

module ActiveMatrix
  # Configuration
  class << self
    attr_accessor :config

    def configure
      @config ||= Configuration.new
      yield @config if block_given?
      @config
    end
  end

  # Configuration class
  class Configuration
    attr_accessor :agent_startup_delay, :max_agents_per_process,
                  :agent_health_check_interval, :conversation_history_limit,
                  :conversation_stale_after, :memory_cleanup_interval,
                  :event_queue_size, :event_processing_timeout,
                  :max_clients_per_homeserver, :client_idle_timeout,
                  :agent_log_level, :log_agent_events,
                  # Daemon settings
                  :daemon_workers, :probe_port, :probe_host, :shutdown_timeout

    def initialize
      # Set defaults
      @agent_startup_delay = 2
      @max_agents_per_process = 10
      @agent_health_check_interval = 30
      @conversation_history_limit = 20
      @conversation_stale_after = 86_400 # 1 day
      @memory_cleanup_interval = 3600 # 1 hour
      @event_queue_size = 1000
      @event_processing_timeout = 30
      @max_clients_per_homeserver = 5
      @client_idle_timeout = 300 # 5 minutes
      @agent_log_level = :info
      @log_agent_events = false
      # Daemon defaults
      @daemon_workers = 1
      @probe_port = 3042
      @probe_host = '127.0.0.1'
      @shutdown_timeout = 30
    end
  end

  # Logger methods
  class << self
    attr_writer :logger

    def logger
      @logger ||= if defined?(::Rails) && ::Rails.respond_to?(:logger)
                    ::Rails.logger
                  else
                    require 'logger'
                    ::Logger.new($stdout)
                  end
    end

    def debug!
      logger.level = if defined?(::Rails)
                       :debug
                     else
                       ::Logger::DEBUG
                     end
    end

    def global_logger?
      instance_variable_defined?(:@logger)
    end

    # Get a client for a named connection
    # @param name [Symbol, String] connection name (default: :primary)
    # @return [ActiveMatrix::Client] authenticated client
    # @example
    #   ActiveMatrix.client.send_message(room_id, message)
    #   ActiveMatrix.client(:notifications).send_notice(room_id, notice)
    def client(name = :primary)
      ConnectionRegistry.instance.client(name)
    end

    # Get connection configuration by name
    # @param name [Symbol, String] connection name (default: :primary)
    # @return [Hash] connection configuration
    def connection(name = :primary)
      ConnectionRegistry.instance.connection(name)
    end

    # Check if a connection exists
    # @param name [Symbol, String] connection name
    # @return [Boolean]
    def connection_exists?(name)
      ConnectionRegistry.instance.connection_exists?(name)
    end

    # List all available connection names
    # @return [Array<String>]
    def connection_names
      ConnectionRegistry.instance.connection_names
    end
  end

  # Set up Zeitwerk loader
  Loader = Zeitwerk::Loader.for_gem

  # Ignore directories and files that shouldn't be autoloaded
  Loader.ignore("#{__dir__}/generators")
  Loader.ignore("#{__dir__}/activematrix.rb")

  # Ignore files that don't follow Zeitwerk naming conventions or are standalone
  Loader.ignore("#{__dir__}/active_matrix/errors.rb")
  Loader.ignore("#{__dir__}/active_matrix/events.rb")
  Loader.ignore("#{__dir__}/active_matrix/uri_module.rb")
  Loader.ignore("#{__dir__}/active_matrix/cli.rb")
  Loader.ignore("#{__dir__}/active_matrix/daemon.rb")
  Loader.ignore("#{__dir__}/active_matrix/daemon")

  # Configure inflections for special cases
  Loader.inflector.inflect(
    'mxid' => 'MXID',
    'uri_module' => 'Uri',
    'as' => 'AS',
    'cs' => 'CS',
    'is' => 'IS',
    'ss' => 'SS',
    'msc' => 'MSC'
  )

  # Setup Zeitwerk autoloading
  Loader.setup

  # Load classes that don't follow Zeitwerk naming conventions
  require_relative 'active_matrix/errors'
  require_relative 'active_matrix/events'
  require_relative 'active_matrix/uri_module'

  # Load Engine for Rails integration
  require 'active_matrix/engine'
end
