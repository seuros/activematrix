# frozen_string_literal: true

module VCRHelper
  # Record new cassettes for all tests in a class
  def self.refresh_cassettes_for(_test_class)
    ENV['VCR_MODE'] = 'new_episodes'
    yield
  ensure
    ENV['VCR_MODE'] = 'once'
  end

  # Helper to create a Matrix client with VCR
  def create_vcr_client(cassette_prefix: nil)
    cassette_name = [cassette_prefix, 'client_creation'].compact.join('_')

    with_vcr_cassette(cassette_name) do
      creds = matrix_test_credentials
      client = ActiveMatrix::Client.new(creds[:server])
      client.login(creds[:username], creds[:password])
      client
    end
  end

  # Helper to clean up test data on the server
  def cleanup_test_rooms(client)
    return unless use_real_matrix_server?

    without_vcr do
      client.rooms.each do |room|
        next unless room.display_name&.start_with?('[TEST]')

        begin
          room.leave
        rescue ActiveMatrix::MatrixError => e
          warn "Failed to leave test room #{room.id}: #{e.message}"
        end
      end
    end
  end

  # Record a cassette with automatic retry on failure
  def record_with_retry(cassette_name, max_retries: 3, &)
    retries = 0
    begin
      with_vcr_cassette(cassette_name, record: :new_episodes, &)
    rescue StandardError => e
      retries += 1
      raise e unless retries < max_retries

      sleep(1)
      retry
    end
  end

  # Helper for filtering room/user IDs in cassettes
  def anonymize_ids(cassette)
    cassette.new_recorded_interactions.each do |interaction|
      # Anonymize room IDs
      interaction.request.uri.gsub!(/![\w-]+:[\w.-]+/, '!ROOM_ID:example.com')
      interaction.response.body.gsub!(/![\w-]+:[\w.-]+/, '!ROOM_ID:example.com')

      # Anonymize user IDs (except test users)
      unless interaction.request.uri.include?('testuser') || interaction.request.uri.include?('seuros')
        interaction.request.uri.gsub!(/@[\w-]+:[\w.-]+/, '@USER_ID:example.com')
        interaction.response.body.gsub!(/@[\w-]+:[\w.-]+/, '@USER_ID:example.com')
      end

      # Anonymize event IDs
      interaction.response.body.gsub!(/\$[\w-]+:[\w.-]+/, '$EVENT_ID:example.com')
    end
  end

  # Create test-specific cassette options
  def vcr_options_for_test(test_name)
    {
      record: vcr_mode,
      match_requests_on: %i[method uri body],
      erb: true, # Allow ERB in cassettes for dynamic content
      preserve_exact_body_bytes: true, # Preserve binary responses
      decode_compressed_response: true, # Handle gzipped responses
      allow_playback_repeats: true, # Allow cassette reuse in same test
      exclusive: true, # Ensure only one cassette at a time
      serialize_with: :json, # Use JSON for better readability
      clean_outdated_http_interactions: true,
      tag: test_name.to_sym
    }
  end

  # VCR cassette for testing specific Matrix endpoints
  module Cassettes
    def self.login_cassette(username: 'testuser')
      "auth/login_#{username}"
    end

    def self.sync_cassette(filter: nil)
      name = 'sync/sync'
      name += "_filtered_#{filter.to_s.gsub(/\W/, '_')}" if filter
      name
    end

    def self.room_cassette(action)
      "rooms/#{action}"
    end

    def self.user_cassette(action)
      "users/#{action}"
    end
  end

  # Protocol test specific helpers
  module ProtocolTests
    def setup_protocol_api(protocols: :CS)
      @api = ActiveMatrix::Api.new(matrix_test_server, protocols: protocols, autoretry: false, threadsafe: false)
      @api
    end

    def vcr_cassette_path
      # Allow test classes to define their own cassette path
      if self.class.const_defined?(:VCR_CASSETTE_PATH)
        self.class.const_get(:VCR_CASSETTE_PATH)
      else
        # Default to a simple api path
        'api/protocol'
      end
    end

    def with_protocol_vcr(test_name, cassette_path: nil, &)
      path = cassette_path || vcr_cassette_path
      cassette_name = "#{path}/#{test_name}"

      # For auth-related tests, ignore body in matching to handle password filtering
      match_on = if test_name.include?('login') || test_name.include?('logout') || test_name.include?('register')
                   %i[method uri_without_param]
                 else
                   %i[method uri_without_param body]
                 end

      options = {
        record: vcr_mode,
        match_requests_on: match_on,
        allow_playback_repeats: true
      }

      with_vcr_cassette(cassette_name, options, &)
    end

    def setup_authenticated_api
      # Use a single shared auth cassette with playback repeats enabled
      # This allows multiple tests to reuse the same login interaction
      options = {
        record: vcr_mode,
        match_requests_on: %i[method uri_without_param],
        allow_playback_repeats: true
      }

      with_vcr_cassette('api/shared_auth_setup', options) do
        api = setup_protocol_api
        creds = matrix_test_credentials
        response = api.login(user: creds[:username], password: creds[:password])
        api.access_token = response[:access_token]
        api
      end
    end

    # Mock a real API response for gradual migration
    def mock_or_real_response(cassette_name, mock_response = nil, &)
      if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
        with_protocol_vcr(cassette_name, &)
      else
        mock_response
      end
    end

    # Create a test room for protocol tests
    def create_test_room(api, name_suffix = nil)
      room_name = "[TEST] Protocol Test Room #{name_suffix || Time.now.to_i}"

      with_protocol_vcr("create_room_#{name_suffix || 'default'}") do
        response = api.create_room(
          name: room_name,
          preset: :public_chat,
          initial_state: []
        )
        response[:room_id]
      end
    end

    # Clean up test room after test
    def cleanup_test_room(api, room_id)
      return unless ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true' && ENV['CLEANUP_TEST_ROOMS'] == 'true'

      without_vcr do
        api.leave_room(room_id) rescue nil
      end
    end
  end

  # Custom VCR matchers
  VCR.configure do |c|
    # Match Matrix API requests ignoring access token
    c.register_request_matcher :matrix_api do |request1, request2|
      uri1 = URI(request1.uri)
      uri2 = URI(request2.uri)

      # Compare paths without access_token parameter
      path1 = "#{uri1.path}?#{uri1.query.to_s.gsub(/access_token=[^&]+/, '')}"
      path2 = "#{uri2.path}?#{uri2.query.to_s.gsub(/access_token=[^&]+/, '')}"

      path1 == path2 && request1.method == request2.method
    end

    # Match URI without specific parameters
    c.register_request_matcher :uri_without_param do |request1, request2|
      # Expand VCR placeholders before comparison
      server = ENV.fetch('MATRIX_TEST_SERVER', 'https://matrix.test.local:8443')
      domain = ENV.fetch('MATRIX_TEST_DOMAIN', 'matrix.test.local')

      uri1_str = request1.uri.gsub('<MATRIX_SERVER>', server).gsub('<MATRIX_DOMAIN>', domain)
      uri2_str = request2.uri.gsub('<MATRIX_SERVER>', server).gsub('<MATRIX_DOMAIN>', domain)

      uri1 = URI(uri1_str)
      uri2 = URI(uri2_str)

      # Remove access_token and txn_id from comparison
      params_to_ignore = %w[access_token txn_id]

      query1 = Rack::Utils.parse_query(uri1.query || '')
      query2 = Rack::Utils.parse_query(uri2.query || '')

      params_to_ignore.each do |param|
        query1.delete(param)
        query2.delete(param)
      end

      uri1.host == uri2.host &&
        uri1.path == uri2.path &&
        query1 == query2
    end
  end
end
