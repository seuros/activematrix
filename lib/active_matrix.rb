# frozen_string_literal: true

require_relative 'active_matrix/version'
require_relative 'active_matrix/logging'
require_relative 'active_matrix/util/extensions'
require_relative 'active_matrix/util/uri'
require_relative 'active_matrix/util/events'
require_relative 'active_matrix/errors'

require 'json'
require 'zeitwerk'
require 'active_support'
require 'active_support/core_ext/integer/time'
require 'active_support/core_ext/time/calculations'
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/object/blank'

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
                  :agent_log_level, :log_agent_events

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
    end
  end

  # Set up Zeitwerk loader
  Loader = Zeitwerk::Loader.for_gem

  # Ignore directories that shouldn't be autoloaded
  Loader.ignore("#{__dir__}/generators")

  # Configure inflections for special cases
  Loader.inflector.inflect(
    'mxid' => 'MXID',
    'uri' => 'URI',
    'as' => 'AS',
    'cs' => 'CS',
    'is' => 'IS',
    'ss' => 'SS',
    'msc' => 'MSC'
  )

  # Setup Zeitwerk autoloading
  Loader.setup

  # Eager load all classes if in Rails eager loading mode
  Loader.eager_load if defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.config&.eager_load

  # Load Railtie for Rails integration
  require 'active_matrix/railtie' if defined?(Rails::Railtie)
end
