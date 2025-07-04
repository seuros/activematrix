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
  end
end

# Include helper in ActiveSupport::TestCase
class ActiveSupport::TestCase
  include VCRHelper
end
