# frozen_string_literal: true

require 'erb'
require 'openssl'
require 'uri'

module ActiveMatrix
  class Api
    extend ActiveMatrix::Extensions
    include ActiveMatrix::Logging

    USER_AGENT = "Ruby Matrix SDK v#{ActiveMatrix::VERSION}".freeze
    DEFAULT_HEADERS = {
      'accept' => 'application/json',
      'user-agent' => USER_AGENT
    }.freeze

    attr_accessor :access_token, :connection_address, :connection_port, :device_id, :autoretry, :global_headers
    attr_reader :homeserver, :validate_certificate, :open_timeout, :read_timeout, :well_known, :proxy_uri, :threadsafe

    ignore_inspect :access_token, :logger

    # @param homeserver [String,URI] The URL to the Matrix homeserver, without the /_matrix/ part
    # @param params [Hash] Additional parameters on creation
    # @option params [Symbol[]] :protocols The protocols to include (:AS, :CS, :IS, :SS), defaults to :CS
    # @option params [String] :address The connection address to the homeserver, if different to the HS URL
    # @option params [Integer] :port The connection port to the homeserver, if different to the HS URL
    # @option params [String] :access_token The access token to use for the connection
    # @option params [String] :device_id The ID of the logged in decide to use
    # @option params [Boolean] :autoretry (true) Should requests automatically be retried in case of rate limits
    # @option params [Boolean] :validate_certificate (false) Should the connection require valid SSL certificates
    # @option params [Integer] :transaction_id (0) The starting ID for transactions
    # @option params [Numeric] :backoff_time (5000) The request backoff time in milliseconds
    # @option params [Numeric] :open_timeout (60) The timeout in seconds to wait for a TCP session to open
    # @option params [Numeric] :read_timeout (240) The timeout in seconds for reading responses
    # @option params [Hash] :global_headers Additional headers to set for all requests
    # @option params [Boolean] :skip_login Should the API skip logging in if the HS URL contains user information
    # @option params [Boolean] :synapse (true) Is the API connecting to a Synapse instance
    # @option params [Boolean,:multithread] :threadsafe (:multithread) Should the connection be threadsafe/mutexed - or
    #   safe for simultaneous multi-thread usage. Will default to +:multithread+ - a.k.a. per-thread HTTP connections
    #   and requests
    # @note Using threadsafe +:multithread+ currently doesn't support connection re-use
    def initialize(homeserver, **params)
      @homeserver = homeserver
      raise ArgumentError, 'Homeserver URL must be String or URI' unless @homeserver.is_a?(String) || @homeserver.is_a?(URI)

      @homeserver = URI.parse("#{'https://' unless @homeserver.start_with? 'http'}#{@homeserver}") unless @homeserver.is_a? URI
      @homeserver.path.gsub!(/\/?_matrix\/?/, '') if /_matrix\/?$/.match?(@homeserver.path)
      raise ArgumentError, 'Please use the base URL for your HS (without /_matrix/)' if @homeserver.path.include? '/_matrix/'

      @proxy_uri = params.fetch(:proxy_uri, nil)
      @connection_address = params.fetch(:address, nil)
      @connection_port = params.fetch(:port, nil)
      @access_token = params.fetch(:access_token, nil)
      @device_id = params.fetch(:device_id, nil)
      @autoretry = params.fetch(:autoretry, true)
      @validate_certificate = params.fetch(:validate_certificate, false)
      @transaction_id = params.fetch(:transaction_id, 0)
      @backoff_time = params.fetch(:backoff_time, 5000)
      @open_timeout = params.fetch(:open_timeout, nil)
      @read_timeout = params.fetch(:read_timeout, nil)
      @well_known = params.fetch(:well_known, {})
      @global_headers = DEFAULT_HEADERS.dup
      @global_headers.merge!(params.fetch(:global_headers)) if params.key? :global_headers
      @synapse = params.fetch(:synapse, true)

      self.threadsafe = params.fetch(:threadsafe, :multithread)

      # Initialize the HTTP client
      @http_client = HttpClient.new(
        @homeserver,
        threadsafe: @threadsafe,
        proxy_uri: @proxy_uri,
        validate_certificate: @validate_certificate,
        open_timeout: @open_timeout,
        read_timeout: @read_timeout,
        global_headers: @global_headers,
        access_token: @access_token,
        logger: logger.debug? ? logger : nil
      )

      ([params.fetch(:protocols, [:CS])].flatten - protocols).each do |proto|
        self.class.include ActiveMatrix::Protocols.const_get(proto)
      end

      login(user: @homeserver.user, password: @homeserver.password) if @homeserver.user && @homeserver.password && !@access_token && !params[:skip_login] && protocol?(:CS)
      @homeserver.userinfo = '' unless params[:skip_login]
    end

    # Create an API connection to a domain entry
    #
    # This will follow the server discovery spec for client-server and federation
    #
    # @example Opening a Matrix API connection to a homeserver
    #   hs = ActiveMatrix::API.new_for_domain 'example.com'
    #   hs.connection_address
    #   # => 'matrix.example.com'
    #   hs.connection_port
    #   # => 443
    #
    # @param domain [String] The domain to set up the API connection for, can contain a ':' to denote a port
    # @param target [:client,:identity,:server] The target for the domain lookup
    # @param keep_wellknown [Boolean] Should the .well-known response be kept for further handling
    # @param params [Hash] Additional options to pass to .new
    # @return [API] The API connection
    def self.new_for_domain(domain, target: :client, keep_wellknown: false, ssl: true, **params)
      domain, port = domain.split(':')
      uri = URI("http#{'s' if ssl}://#{domain}")
      well_known = nil
      target_uri = nil
      logger = ActiveMatrix.logger
      logger.debug "Resolving #{domain}"

      if port.present?
        # If the domain is fully qualified according to Matrix (FQDN and port) then skip discovery
        target_uri = URI("https://#{domain}:#{port}")
      elsif target == :server
        # Attempt SRV record discovery
        target_uri = begin
          require 'resolv'
          resolver = Resolv::DNS.new
          srv = "_matrix._tcp.#{domain}"
          logger.debug "Trying DNS #{srv}..."
          d = resolver.getresource(srv, Resolv::DNS::Resource::IN::SRV)
          d
        rescue StandardError => e
          logger.debug "DNS lookup failed with #{e.class}: #{e.message}"
          nil
        end

        if target_uri.nil?
          # Attempt .well-known discovery for server-to-server
          well_known = begin
            wk_uri = URI("https://#{domain}/.well-known/matrix/server")
            logger.debug "Trying #{wk_uri}..."
            conn = Faraday.new(url: "https://#{wk_uri.host}") do |f|
              f.options.open_timeout = 5
              f.options.timeout = 5
              f.adapter :net_http
            end
            data = conn.get(wk_uri.path).body
            JSON.parse(data)
          rescue StandardError => e
            logger.debug "Well-known failed with #{e.class}: #{e.message}"
            nil
          end

          target_uri = well_known['m.server'] if well_known&.key?('m.server')
        else
          target_uri = URI("https://#{target_uri.target}:#{target_uri.port}")
        end
      elsif %i[client identity].include? target
        # Attempt .well-known discovery
        well_known = begin
          wk_uri = URI("https://#{domain}/.well-known/matrix/client")
          logger.debug "Trying #{wk_uri}..."
          conn = Faraday.new(url: "https://#{wk_uri.host}") do |f|
            f.options.open_timeout = 5
            f.options.timeout = 5
            f.adapter :net_http
          end
          data = conn.get(wk_uri.path).body
          JSON.parse(data)
        rescue StandardError => e
          logger.debug "Well-known failed with #{e.class}: #{e.message}"
          nil
        end

        if well_known
          key = 'm.homeserver'
          key = 'm.identity_server' if target == :identity

          if well_known.key?(key) && well_known[key].key?('base_url')
            uri = URI(well_known[key]['base_url'])
            target_uri = uri
          end
        end
      end
      logger.debug "Using #{target_uri.inspect}"

      # Fall back to direct domain connection
      target_uri ||= URI("https://#{domain}:8448")

      params[:well_known] = well_known if keep_wellknown

      new(
        uri,
        **params, address: target_uri.host,
                  port: target_uri.port
      )
    end

    # Get a list of enabled protocols on the API client
    #
    # @example
    #   ActiveMatrix::Api.new_for_domain('matrix.org').protocols
    #   # => [:IS, :CS]
    #
    # @return [Symbol[]] An array of enabled APIs
    def protocols
      self
        .class.included_modules
        .reject { |m| m&.name.nil? }
        .select { |m| m.name.start_with? 'ActiveMatrix::Protocols::' }
        .map { |m| m.name.split('::').last.to_sym }
    end

    # Check if a protocol is enabled on the API connection
    #
    # @example Checking for identity server API support
    #   api.protocol? :IS
    #   # => false
    #
    # @param protocol [Symbol] The protocol to check
    # @return [Boolean] Is the protocol enabled
    def protocol?(protocol)
      protocols.include? protocol
    end

    # @param seconds [Numeric]
    # @return [Numeric]
    def open_timeout=(seconds)
      return unless @open_timeout != seconds

      @http_client&.close
      @open_timeout = seconds
      # Reinitialize HTTP client with new timeout
      reinitialize_http_client
    end

    # @param seconds [Numeric]
    # @return [Numeric]
    def read_timeout=(seconds)
      return unless @read_timeout != seconds

      @http_client&.close
      @read_timeout = seconds
      # Reinitialize HTTP client with new timeout
      reinitialize_http_client
    end

    # @param validate [Boolean]
    # @return [Boolean]
    def validate_certificate=(validate)
      return unless validate != @validate_certificate

      @http_client&.close
      @validate_certificate = validate
      # Reinitialize HTTP client with new certificate validation
      reinitialize_http_client
    end

    # @param hs_info [URI]
    # @return [URI]
    def homeserver=(hs_info)
      # TODO: DNS query for SRV information about HS?
      return unless hs_info.is_a? URI

      @http_client&.close if homeserver != hs_info
      @homeserver = hs_info
      reinitialize_http_client if homeserver != hs_info
    end

    # @param [URI] proxy_uri The URI for the proxy to use
    # @return [URI]
    def proxy_uri=(proxy_uri)
      proxy_uri = URI(proxy_uri.to_s) unless proxy_uri.is_a? URI

      return unless @proxy_uri != proxy_uri

      @http_client&.close
      @proxy_uri = proxy_uri
      reinitialize_http_client
    end

    # @param [Boolean,:multithread] threadsafe What level of thread-safety the API should use
    # @return [Boolean,:multithread]
    def threadsafe=(threadsafe)
      raise ArgumentError, 'Threadsafe must be either a boolean or :multithread' unless [true, false, :multithread].include? threadsafe
      raise ArugmentError, 'JRuby only support :multithread/false for threadsafe' if RUBY_ENGINE == 'jruby' && threadsafe == true

      @threadsafe = threadsafe
    end

    # Perform a raw Matrix API request
    #
    # @example Simple API query
    #   api.request(:get, :client_v3, '/account/whoami')
    #   # => { :user_id => "@alice:matrix.org" }
    #
    # @example Advanced API request
    #   api.request(:post,
    #               :media_r0,
    #               '/upload',
    #               body_stream: open('./file'),
    #               headers: { 'content-type' => 'image/png' })
    #   # => { :content_uri => "mxc://example.com/AQwafuaFswefuhsfAFAgsw" }
    #
    # @param method [Symbol] The method to use (:get, :post, :put, :delete, etc.)
    # @param api [Symbol] The API symbol to use, :client_v3 is the current CS one
    # @param path [String] The API path to call, this is the part that comes after the API definition in the spec
    # @param options [Hash] Additional options to pass along to the request
    # @option options [Hash] :query Query parameters to set on the URL
    # @option options [Hash,String] :body The body to attach to the request, will be JSON-encoded if sent as a hash
    # @option options [IO] :body_stream A body stream to attach to the request
    # @option options [Hash] :headers Additional headers to set on the request
    # @option options [Boolean] :skip_auth (false) Skip authentication
    def request(method, api, path, **options)
      full_path = api_to_path(api) + path

      # Update access token if it changed
      @http_client.access_token = @access_token if @http_client.access_token != @access_token

      failures = 0
      loop do
        raise MatrixConnectionError, "Server still too busy to handle request after #{failures} attempts, try again later" if failures >= 10

        req_id = ('A'..'Z').to_a.sample(4).join

        # Log request
        if logger.debug?
          logger.debug "#{req_id} : > Sending a #{method.to_s.upcase} request to `#{full_path}`"
          logger.debug "#{req_id} : > Query: #{options[:query].inspect}" if options[:query]
          logger.debug "#{req_id} : > Body: #{options[:body].to_json}" if options[:body] && !options[:body].is_a?(String)
        end

        dur_start = Time.zone.now
        begin
          response = @http_client.request(method, full_path, **options)
        rescue Faraday::Error => e
          logger.error "Request failed: #{e.message}"
          raise MatrixConnectionError, e.message
        end
        dur_end = Time.zone.now
        duration = dur_end - dur_start

        # Log response
        if logger.debug?
          logger.debug "#{req_id} : < Received a #{response.status} response: [#{(duration * 1000).to_i}ms]"
          logger.debug "#{req_id} : < Body: #{response.body.inspect}" if response.body
        end

        # Handle rate limiting (429)
        if response.status == 429
          raise MatrixRequestError.new_by_code(response.body, response.status.to_s) unless autoretry

          failures += 1
          waittime = response.body[:retry_after_ms] || response.body.dig(:error, :retry_after_ms) || @backoff_time
          sleep(waittime.to_f / 1000.0)
          next
        end

        # Handle success (2xx)
        if response.success?
          unless response.body
            logger.error "Received non-parsable data in #{response.status} response"
            raise MatrixConnectionError, 'Empty response body'
          end
          return ActiveMatrix::Response.new self, response.body
        end

        # Handle other errors
        raise MatrixRequestError.new_by_code(response.body, response.status.to_s) if response.body && response.body.is_a?(Hash)

        raise MatrixConnectionError.class_by_code(response.status.to_s), "HTTP #{response.status}"
      end
    end

    # Generate a transaction ID
    #
    # @return [String] An arbitrary transaction ID
    def transaction_id
      ret = @transaction_id ||= 0
      @transaction_id = @transaction_id.succ
      ret
    end

    private

    def reinitialize_http_client
      @http_client = HttpClient.new(
        @homeserver,
        threadsafe: @threadsafe,
        proxy_uri: @proxy_uri,
        validate_certificate: @validate_certificate,
        open_timeout: @open_timeout,
        read_timeout: @read_timeout,
        global_headers: @global_headers,
        access_token: @access_token,
        logger: logger.debug? ? logger : nil
      )
    end

    def api_to_path(api)
      return "/_synapse/#{api.to_s.split('_').join('/')}" if @synapse && api.to_s.start_with?('admin_')

      # TODO: <api>_current / <api>_latest
      "/_matrix/#{api.to_s.split('_').join('/')}"
    end
  end
end
