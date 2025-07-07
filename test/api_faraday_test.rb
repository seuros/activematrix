# frozen_string_literal: true

require 'test_helper'

class ApiFaradayTest < ActiveSupport::TestCase
  def setup
    @api = ActiveMatrix::Api.new('https://example.com')
  end

  def test_uses_faraday_by_default
    assert_not_nil @api.instance_variable_get(:@http_client)
    assert_instance_of ActiveMatrix::HttpClient, @api.instance_variable_get(:@http_client)
  end

  def test_request_with_faraday
    # Create a test stub for Faraday
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get('/_matrix/client/v3/account/whoami') do |env|
      assert_equal 'Bearer test_token', env.request_headers['Authorization']
      [200, { 'Content-Type' => 'application/json' }, { user_id: '@alice:example.com' }.to_json]
    end

    @api.access_token = 'test_token'

    # Override the HTTP client to use test stubs
    http_client = @api.instance_variable_get(:@http_client)
    http_client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    response = @api.request(:get, :client_v3, '/account/whoami')

    assert_equal '@alice:example.com', response[:user_id]
    stubs.verify_stubbed_calls
  end

  def test_request_with_query_params
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get('/_matrix/client/v3/sync?timeout=30000&since=s123') do
      [200, { 'Content-Type' => 'application/json' }, { next_batch: 's124' }.to_json]
    end

    http_client = @api.instance_variable_get(:@http_client)
    http_client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    response = @api.request(:get, :client_v3, '/sync', query: { timeout: 30_000, since: 's123' })

    assert_equal 's124', response[:next_batch]
    stubs.verify_stubbed_calls
  end

  def test_request_with_json_body
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.post('/_matrix/client/v3/rooms/!room:example.com/send/m.room.message') do |env|
      body = JSON.parse(env.body, symbolize_names: true)

      assert_equal 'Hello', body[:body]
      assert_equal 'm.text', body[:msgtype]
      [200, { 'Content-Type' => 'application/json' }, { event_id: '$event123' }.to_json]
    end

    http_client = @api.instance_variable_get(:@http_client)
    http_client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    response = @api.request(:post, :client_v3, '/rooms/!room:example.com/send/m.room.message',
                            body: { body: 'Hello', msgtype: 'm.text' })

    assert_equal '$event123', response[:event_id]
    stubs.verify_stubbed_calls
  end

  def test_rate_limiting_with_retry
    attempts = 0
    stubs = Faraday::Adapter::Test::Stubs.new

    # First request returns 429
    stubs.get('/_matrix/client/v3/sync') do
      attempts += 1
      if attempts == 1
        [429, { 'Content-Type' => 'application/json' },
         { error: 'Too many requests', retry_after_ms: 100 }.to_json]
      else
        [200, { 'Content-Type' => 'application/json' }, { next_batch: 's124' }.to_json]
      end
    end

    http_client = @api.instance_variable_get(:@http_client)
    http_client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    # Expect sleep to be called
    @api.expects(:sleep).with(0.1)

    response = @api.request(:get, :client_v3, '/sync')

    assert_equal 's124', response[:next_batch]
    assert_equal 2, attempts
    stubs.verify_stubbed_calls
  end

  def test_error_handling
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get('/_matrix/client/v3/unknown') do
      [404, { 'Content-Type' => 'application/json' },
       { errcode: 'M_NOT_FOUND', error: 'Unknown endpoint' }.to_json]
    end

    http_client = @api.instance_variable_get(:@http_client)
    http_client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    assert_raises(ActiveMatrix::MatrixNotFoundError) do
      @api.request(:get, :client_v3, '/unknown')
    end

    stubs.verify_stubbed_calls
  end
end
