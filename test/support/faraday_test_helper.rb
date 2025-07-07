# frozen_string_literal: true

require 'faraday'

module FaradayTestHelper
  # Prevent any real HTTP requests in tests
  def setup_faraday_stubs
    @faraday_stubs = Faraday::Adapter::Test::Stubs.new
  end

  # Override HttpClient to use test adapter
  def stub_http_client(api)
    return unless api.instance_variable_get(:@http_client)

    http_client = api.instance_variable_get(:@http_client)
    # Store the original stubs for this client
    http_client.instance_variable_set(:@test_stubs, @faraday_stubs)

    http_client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, @test_stubs
        end
      end
    end
  end

  # Helper to stub a request
  def stub_faraday_request(method, path, response_body, status: 200, headers: {})
    @faraday_stubs.send(method, path) do |_env|
      [
        status,
        { 'Content-Type' => 'application/json' }.merge(headers),
        response_body.is_a?(String) ? response_body : response_body.to_json
      ]
    end
  end

  # Verify all stubbed requests were called
  def verify_faraday_stubs
    @faraday_stubs.verify_stubbed_calls
  end

  # Prevent any HTTP requests (similar to Net::HTTP.any_instance.expects(:request).never)
  def expect_no_http_requests
    if defined?(@faraday_stubs)
      # Faraday test adapter will fail if any unstubbed request is made
    else
      # Keep Net::HTTP prevention for backward compatibility
      ::Net::HTTP.any_instance.expects(:request).never
    end
  end
end
