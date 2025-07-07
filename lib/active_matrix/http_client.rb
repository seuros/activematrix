# frozen_string_literal: true

require 'faraday'
require 'faraday/net_http_persistent'
require 'faraday/retry'
require 'json'

module ActiveMatrix
  class HttpClient
    attr_reader :homeserver, :connection_options, :threadsafe_mode
    attr_accessor :access_token, :global_headers

    # Initialize a new HTTP client with Faraday
    # @param homeserver [URI] The homeserver URI
    # @param options [Hash] Configuration options
    # @option options [Symbol] :threadsafe Threading mode (:multithread, true, false)
    # @option options [URI] :proxy_uri Proxy configuration
    # @option options [Boolean] :validate_certificate SSL certificate validation
    # @option options [Integer] :open_timeout Connection open timeout
    # @option options [Integer] :read_timeout Read timeout
    # @option options [Hash] :global_headers Headers to include in all requests
    def initialize(homeserver, **options)
      @homeserver = homeserver
      @threadsafe_mode = options[:threadsafe] || false
      @connection_options = options
      @global_headers = options[:global_headers] || {}
      @access_token = options[:access_token]

      @connections = {} if threadsafe_mode == :multithread
      @connection_lock = Mutex.new if threadsafe_mode == true
    end

    # Perform an HTTP request
    # @param method [Symbol] HTTP method (:get, :post, etc.)
    # @param path [String] Request path
    # @param options [Hash] Request options
    # @return [Faraday::Response]
    def request(method, path, **options)
      connection = get_connection

      response = connection.send(method) do |req|
        req.url path

        # Set headers
        req.headers.merge!(@global_headers)
        req.headers['Authorization'] = "Bearer #{@access_token}" if @access_token && !options[:skip_auth]
        req.headers.merge!(options[:headers]) if options[:headers]

        # Set query parameters
        req.params.merge!(options[:query]) if options[:query]

        # Set body
        if options.key?(:body)
          # For GET requests with nil body, send 'null' to match Net::HTTP behavior for VCR compatibility
          if method == :get && options[:body].nil?
            req.body = 'null'
            req.headers['Content-Type'] = 'application/json'
          elsif options[:body].nil?
            # Match Net::HTTP behavior - send 'null' for nil body on non-GET requests
            req.body = 'null'
            req.headers['Content-Type'] = 'application/json'
          elsif options[:body].is_a?(String)
            req.body = options[:body]
          else
            req.body = options[:body].to_json
            req.headers['Content-Type'] = 'application/json'
          end
        elsif options[:body_stream]
          req.body = options[:body_stream]
          req.headers['Content-Type'] = options[:content_type] || 'application/octet-stream'
        end
      end

      response
    ensure
      release_connection(connection) if threadsafe_mode == :multithread
    end

    # Close all connections
    def close
      case threadsafe_mode
      when :multithread
        @connections.each_value(&:close)
        @connections.clear
      when true, false
        @connection&.close if @connection
        @connection = nil
      end
    end

    private

    def get_connection
      case threadsafe_mode
      when :multithread
        # Per-thread connection
        thread_id = Thread.current.object_id
        @connections[thread_id] ||= build_connection
      when true
        # Shared connection with mutex
        @connection_lock.synchronize do
          @connection ||= build_connection
        end
      else
        # Single connection, not thread-safe
        @connection ||= build_connection
      end
    end

    def release_connection(_connection)
      nil unless threadsafe_mode == :multithread
      # In multithread mode, we could implement connection pooling
      # For now, connections stay alive per thread
    end

    def build_connection
      Faraday.new(url: @homeserver.to_s) do |faraday|
        # Request/Response middleware
        faraday.request :json
        faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }

        # Logging middleware (optional)
        if @connection_options[:logger]
          faraday.response :logger, @connection_options[:logger] do |logger|
            logger.filter(/(Authorization:)(.*)/, '\1 [REDACTED]')
          end
        end

        # Retry middleware for rate limiting
        faraday.request :retry, {
          max: 10,
          interval: 0.05,
          backoff_factor: 2,
          retry_statuses: [429],
          retry_block: lambda do |env, _options, _retries, _exception|
            if env.status == 429 && env.response_body
              retry_after = parse_retry_after(env.response_body)
              sleep(retry_after / 1000.0) if retry_after
            end
          end
        }

        # Adapter configuration
        adapter_options = {
          open_timeout: @connection_options[:open_timeout] || 60,
          timeout: @connection_options[:read_timeout] || 240
        }

        # Proxy configuration
        if @connection_options[:proxy_uri]
          proxy = @connection_options[:proxy_uri]
          adapter_options[:proxy] = {
            uri: proxy.to_s,
            user: proxy.user,
            password: proxy.password
          }
        end

        # SSL configuration
        adapter_options[:ssl] = {
          verify: @connection_options[:validate_certificate] != false
        }

        # Use persistent adapter for connection reuse
        faraday.adapter :net_http_persistent, adapter_options
      end
    end

    def parse_retry_after(response_body)
      data = JSON.parse(response_body, symbolize_names: true) rescue {}
      data[:retry_after_ms] || data.dig(:error, :retry_after_ms)
    end
  end
end
