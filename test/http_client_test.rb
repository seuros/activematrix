# frozen_string_literal: true

require 'test_helper'

class HttpClientTest < ActiveSupport::TestCase
  def setup
    @homeserver = URI.parse('https://example.com')
    @client = ActiveMatrix::HttpClient.new(@homeserver)
  end

  def test_basic_request
    # Use Faraday test adapter
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get('/_matrix/client/r0/account/whoami') do |env|
      assert_equal 'Bearer test_token', env.request_headers['Authorization']
      [200, { 'Content-Type' => 'application/json' }, { user_id: '@alice:example.com' }.to_json]
    end

    @client.access_token = 'test_token'

    # Override connection to use test adapter
    @client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    response = @client.request(:get, '/_matrix/client/r0/account/whoami')

    assert_equal 200, response.status
    assert_equal '@alice:example.com', response.body[:user_id]

    stubs.verify_stubbed_calls
  end

  def test_post_with_json_body
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.post('/_matrix/client/r0/rooms/!room:example.com/send/m.room.message') do |env|
      assert_equal 'application/json', env.request_headers['Content-Type']
      body = JSON.parse(env.body, symbolize_names: true)

      assert_equal 'Hello', body[:body]
      assert_equal 'm.text', body[:msgtype]
      [200, { 'Content-Type' => 'application/json' }, { event_id: '$event123' }.to_json]
    end

    @client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    response = @client.request(:post, '/_matrix/client/r0/rooms/!room:example.com/send/m.room.message',
                               body: { body: 'Hello', msgtype: 'm.text' })

    assert_equal 200, response.status
    assert_equal '$event123', response.body[:event_id]

    stubs.verify_stubbed_calls
  end

  def test_query_parameters
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get('/_matrix/client/r0/sync?timeout=30000&since=s123') do
      [200, { 'Content-Type' => 'application/json' }, { next_batch: 's124' }.to_json]
    end

    @client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.request :json
          faraday.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: true }
          faraday.adapter :test, stubs
        end
      end
    end

    response = @client.request(:get, '/_matrix/client/r0/sync',
                               query: { timeout: 30_000, since: 's123' })

    assert_equal 200, response.status
    assert_equal 's124', response.body[:next_batch]

    stubs.verify_stubbed_calls
  end

  def test_global_headers
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get('/test') do |env|
      assert_equal 'CustomValue', env.request_headers['X-Custom-Header']
      assert_equal 'Ruby Matrix SDK', env.request_headers['User-Agent']
      [200, {}, '{}']
    end

    client = ActiveMatrix::HttpClient.new(@homeserver,
                                          global_headers: {
                                            'X-Custom-Header' => 'CustomValue',
                                            'User-Agent' => 'Ruby Matrix SDK'
                                          })

    client.instance_eval do
      define_singleton_method(:build_connection) do
        Faraday.new(url: @homeserver.to_s) do |faraday|
          faraday.adapter :test, stubs
        end
      end
    end

    response = client.request(:get, '/test')

    assert_equal 200, response.status

    stubs.verify_stubbed_calls
  end

  def test_threading_modes
    # Test :multithread mode creates per-thread connections
    client = ActiveMatrix::HttpClient.new(@homeserver, threadsafe: :multithread)

    connections = []
    threads = 2.times.map do
      Thread.new do
        conn = client.send(:get_connection)
        connections << conn.object_id
      end
    end
    threads.each(&:join)

    assert_equal 2, connections.uniq.size, 'Should have different connections per thread'

    # Test true mode uses mutex
    client = ActiveMatrix::HttpClient.new(@homeserver, threadsafe: true)

    assert_instance_of Mutex, client.instance_variable_get(:@connection_lock)

    # Test false mode has no special handling
    client = ActiveMatrix::HttpClient.new(@homeserver, threadsafe: false)

    assert_nil client.instance_variable_get(:@connection_lock)
    assert_nil client.instance_variable_get(:@connections)
  end

  def test_close_connections
    client = ActiveMatrix::HttpClient.new(@homeserver, threadsafe: :multithread)

    # Create some connections
    Thread.new { client.send(:get_connection) }.join
    Thread.new { client.send(:get_connection) }.join

    connections = client.instance_variable_get(:@connections)

    assert_not_empty connections

    client.close

    connections = client.instance_variable_get(:@connections)

    assert_empty connections
  end
end
