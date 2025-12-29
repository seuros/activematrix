# frozen_string_literal: true

require 'yaml'
require 'erb'
require 'singleton'

module ActiveMatrix
  # Registry for named Matrix connections loaded from config/active_matrix.yml
  #
  # Connections are defined in YAML with ERB support for secrets:
  #
  #   primary:
  #     homeserver_url: <%= ENV['MATRIX_HOMESERVER_URL'] %>
  #     access_token: <%= ENV['MATRIX_ACCESS_TOKEN'] %>
  #
  # Usage:
  #   ActiveMatrix.connection(:primary)  # Returns connection config hash
  #   ActiveMatrix.client(:primary)      # Returns authenticated Client
  #
  class ConnectionRegistry
    include Singleton

    class ConnectionNotFound < StandardError; end

    def initialize
      @connections = {}
      @clients = {}
      @mutex = Mutex.new
    end

    # Load connections from YAML file
    # @param path [String, Pathname] path to YAML config file
    def load!(path)
      @mutex.synchronize do
        @connections = load_yaml(path)
        @clients.clear # Clear cached clients when config reloads
      end
    end

    # Get connection configuration by name
    # @param name [Symbol, String] connection name (default: :primary)
    # @return [Hash] connection configuration
    # @raise [ConnectionNotFound] if connection doesn't exist
    def connection(name = :primary)
      name = name.to_s
      config = @connections[name]
      raise ConnectionNotFound, "Connection '#{name}' not found in config/active_matrix.yml" unless config

      config.symbolize_keys
    end

    # Get or create a client for a named connection
    # @param name [Symbol, String] connection name (default: :primary)
    # @return [ActiveMatrix::Client] authenticated client
    def client(name = :primary)
      name = name.to_s

      @mutex.synchronize do
        @clients[name] ||= build_client(name)
      end
    end

    # Check if a connection exists
    # @param name [Symbol, String] connection name
    # @return [Boolean]
    def connection_exists?(name)
      @connections.key?(name.to_s)
    end

    # List all available connection names
    # @return [Array<String>]
    def connection_names
      @connections.keys - ['default']
    end

    # Clear all cached clients (useful for testing)
    def clear_clients!
      @mutex.synchronize do
        @clients.each_value do |client|
          client.logout if client.logged_in?
        rescue StandardError
          # Ignore cleanup errors
        end
        @clients.clear
      end
    end

    # Reload configuration from file
    # @param path [String, Pathname] path to YAML config file
    def reload!(path = nil)
      path ||= default_config_path
      clear_clients!
      load!(path)
    end

    private

    def load_yaml(path)
      return {} unless File.exist?(path)

      yaml_content = File.read(path)
      erb_result = ERB.new(yaml_content).result
      config = YAML.safe_load(erb_result, permitted_classes: [], permitted_symbols: [], aliases: true) || {}

      # Filter out 'default' key which is just for YAML anchors
      config.except('default')
    end

    def build_client(name)
      config = connection(name)

      raise ConnectionNotFound, "Connection '#{name}' missing homeserver_url" unless config[:homeserver_url]

      client = ActiveMatrix::Client.new(
        config[:homeserver_url],
        client_cache: :some,
        sync_filter_limit: config[:sync_filter_limit] || 20
      )

      # Authenticate if access_token provided
      if config[:access_token]
        client.access_token = config[:access_token]
      elsif config[:username] && config[:password]
        client.login(config[:username], config[:password], no_sync: true)
      end

      client
    end

    def default_config_path
      return Rails.root.join('config/active_matrix.yml') if defined?(Rails)

      File.join(Dir.pwd, 'config', 'active_matrix.yml')
    end
  end
end
