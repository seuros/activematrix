# frozen_string_literal: true

require 'test_helper'

require 'net/http'
require 'resolv'
require 'ostruct'

class ApiTest < ActiveSupport::TestCase
  def test_creation
    api = ActiveMatrix::Api.new 'https://matrix.example.com/_matrix/'

    assert_equal URI('https://matrix.example.com'), api.homeserver

    api = ActiveMatrix::Api.new 'matrix.com'

    assert_equal URI('https://matrix.com'), api.homeserver
  end

  def test_creation_with_as_protocol
    api = ActiveMatrix::Api.new 'https://matrix.example.com', protocols: :AS

    assert api.protocol? :AS
    # Ensure CS protocol is also provided
    assert_respond_to api, :join_room
  end

  def test_creation_with_cs_protocol
    api = ActiveMatrix::Api.new 'https://matrix.example.com'

    assert_respond_to api, :join_room
    # assert !api.respond_to?(:identity_status) # No longer true since the definite include
  end

  def test_creation_with_is_protocol
    api = ActiveMatrix::Api.new 'https://matrix.example.com', protocols: :IS

    # assert !api.respond_to?(:join_room) # No longer true since the definite include
    assert_respond_to api, :identity_status
  end

  def test_fail_creation
    assert_raises(ArgumentError) { ActiveMatrix::Api.new :test }
    assert_raises(ArgumentError) { ActiveMatrix::Api.new URI() }
  end

  # This test is more complicated due to testing protocol extensions and auto-login all in the initializer
  def test_creation_with_login
    matrixsdk_add_api_stub
    ActiveMatrix::Api
      .any_instance
      .expects(:request)
      .with(:post, :client_v3, '/login',
            body: {
              type: 'm.login.password',
              initial_device_display_name: ActiveMatrix::Api::USER_AGENT,
              user: 'user',
              password: 'pass'
            },
            query: {})
      .returns(ActiveMatrix::Response.new(nil, token: 'token', device_id: 'device id'))

    api = ActiveMatrix::Api.new 'https://user:pass@matrix.example.com/_matrix/'

    assert_equal URI('https://matrix.example.com'), api.homeserver
  end

  def test_client_creation_for_domain
    matrixsdk_add_api_stub
    ::Resolv::DNS
      .any_instance
      .expects(:getresource)
      .never

    # Mock Faraday connection for well-known discovery
    faraday_conn = mock
    faraday_response = mock
    faraday_response.stubs(:body).returns('{"m.homeserver":{"base_url":"https://matrix.example.com"}}')

    faraday_conn.expects(:get).with('/.well-known/matrix/client').returns(faraday_response)

    Faraday.expects(:new).with(url: 'https://example.com').yields(mock.tap do |builder|
      builder.stubs(:options).returns(OpenStruct.new)
      builder.expects(:adapter).with(:net_http)
    end).returns(faraday_conn)

    ActiveMatrix::Api
      .expects(:new)
      .with(URI('https://matrix.example.com'), address: 'matrix.example.com', port: 443)

    ActiveMatrix::Api.new_for_domain 'example.com', target: :client
  end

  def test_server_creation_for_domain
    matrixsdk_add_api_stub
    ::Resolv::DNS
      .any_instance
      .expects(:getresource)
      .returns(Resolv::DNS::Resource::IN::SRV.new(10, 1, 443, 'matrix.example.com'))

    ::Net::HTTP
      .any_instance
      .expects(:get)
      .never

    ActiveMatrix::Api
      .expects(:new)
      .with(URI('https://example.com'), address: 'matrix.example.com', port: 443)

    ActiveMatrix::Api.new_for_domain 'example.com', target: :server
  end

  def test_server_creation_for_missing_domain
    matrixsdk_add_api_stub
    ::Resolv::DNS
      .any_instance
      .expects(:getresource)
      .raises(::Resolv::ResolvError)

    # Mock Faraday connection for well-known discovery
    faraday_conn = mock

    faraday_conn.expects(:get).with('/.well-known/matrix/server').raises(StandardError)

    Faraday.expects(:new).with(url: 'https://example.com').yields(mock.tap do |builder|
      builder.stubs(:options).returns(OpenStruct.new)
      builder.expects(:adapter).with(:net_http)
    end).returns(faraday_conn)

    ActiveMatrix::Api
      .expects(:new)
      .with(URI('https://example.com'), address: 'example.com', port: 8448)

    ActiveMatrix::Api.new_for_domain 'example.com', target: :server
  end

  def test_server_creation_for_domain_and_port
    matrixsdk_add_api_stub
    ActiveMatrix::Api
      .expects(:new)
      .with(URI('https://example.com'), address: 'example.com', port: 8448)

    ActiveMatrix::Api.new_for_domain 'example.com:8448', target: :server
  end

  def test_failed_creation_with_domain
    matrixsdk_add_api_stub
    ::Resolv::DNS
      .any_instance
      .stubs(:getresource)
      .raises(::Resolv::ResolvError)

    # Mock Faraday connections for well-known discovery
    # First call for server target
    faraday_conn_server = mock
    faraday_conn_server.expects(:get).with('/.well-known/matrix/server').raises(StandardError)

    Faraday.expects(:new).with(url: 'https://example.com').yields(mock.tap do |builder|
      builder.stubs(:options).returns(OpenStruct.new)
      builder.expects(:adapter).with(:net_http)
    end).returns(faraday_conn_server)

    api = ActiveMatrix::Api.new_for_domain('example.com', target: :server)

    assert_equal 'https://example.com', api.homeserver.to_s
    assert_equal 'example.com', api.connection_address
    assert_equal 8448, api.connection_port

    # Second call for client target
    faraday_conn_client = mock
    faraday_conn_client.expects(:get).with('/.well-known/matrix/client').raises(StandardError)

    Faraday.expects(:new).with(url: 'https://example.com').yields(mock.tap do |builder|
      builder.stubs(:options).returns(OpenStruct.new)
      builder.expects(:adapter).with(:net_http)
    end).returns(faraday_conn_client)

    api = ActiveMatrix::Api.new_for_domain('example.com', target: :client)

    assert_equal 'https://example.com', api.homeserver.to_s
    assert_equal 'example.com', api.connection_address
    assert_equal 8448, api.connection_port
  end

  def test_http_request_logging
    skip 'Logging is now handled by Faraday middleware'
  end

  def test_http_response_logging
    skip 'Logging is now handled by Faraday middleware'
  end

  def test_requests
    # Test is now covered by api_faraday_test.rb
    skip 'Request handling is now tested in api_faraday_test.rb'
  end

  def test_http_changes
    matrixsdk_add_api_stub
    api = ActiveMatrix::Api.new 'https://example.com'

    api.read_timeout = 5

    assert_equal 5, api.read_timeout

    api.validate_certificate = true

    assert api.validate_certificate

    api.homeserver = URI('https://matrix.example.com')

    assert_equal 'matrix.example.com', api.homeserver.host

    api.proxy_uri = URI('http://squid-proxy.example.com:3128')

    assert_equal 'squid-proxy.example.com', api.proxy_uri.host

    # Verify that the HTTP client is recreated with new settings
    http_client = api.instance_variable_get(:@http_client)

    assert_not_nil http_client
    assert_equal 5, http_client.connection_options[:read_timeout]
    assert_equal true, http_client.connection_options[:validate_certificate]
    assert_equal api.proxy_uri, http_client.connection_options[:proxy_uri]
  end

  class DummyError < StandardError; end

  def test_request_paths
    matrixsdk_add_api_stub
    api = ActiveMatrix::Api.new 'https://example.com'

    # Stub the HTTP client to verify request paths
    http_client = api.instance_variable_get(:@http_client)

    # Test client path
    http_client.expects(:request).with(:get, '/_matrix/client/v3/account/whoami', anything).raises(DummyError)
    assert_raises(DummyError) { api.request(:get, :client_v3, '/account/whoami') }

    # Test admin/synapse path
    http_client.expects(:request).with(:post, '/_synapse/admin/v1/account_validity/validity', anything).raises(DummyError)
    assert_raises(DummyError) { api.request(:post, :admin_v1, '/account_validity/validity') }
  end
end
