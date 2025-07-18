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
      .with(:post, :client_r0, '/login',
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

    http_mock = mock

    http_mock
      .expects(:get)
      .with('/.well-known/matrix/client')
      .returns(stub(body: '{"m.homeserver":{"base_url":"https://matrix.example.com"}}'))

    Net::HTTP
      .expects(:start)
      .with('example.com', 443, use_ssl: true, open_timeout: 5, read_timeout: 5, write_timeout: 5)
      .with_block_given
      .yields(http_mock)
      .returns('{"m.homeserver":{"base_url":"https://matrix.example.com"}}')

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

    http_mock = mock

    http_mock
      .expects(:get)
      .with('/.well-known/matrix/server')
      .once
      .raises(StandardError)

    Net::HTTP
      .expects(:start)
      .with('example.com', 443, use_ssl: true, open_timeout: 5, read_timeout: 5, write_timeout: 5)
      .with_block_given
      .yields(http_mock)

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

    http_mock = mock

    http_mock
      .expects(:get)
      .with('/.well-known/matrix/server')
      .once
      .raises(StandardError)

    http_mock
      .expects(:get)
      .with('/.well-known/matrix/client')
      .once
      .raises(StandardError)

    Net::HTTP
      .expects(:start)
      .with('example.com', 443, use_ssl: true, open_timeout: 5, read_timeout: 5, write_timeout: 5)
      .with_block_given
      .yields(http_mock)
      .twice

    api = ActiveMatrix::Api.new_for_domain('example.com', target: :server)

    assert_equal 'https://example.com', api.homeserver.to_s
    assert_equal 'example.com', api.connection_address
    assert_equal 8448, api.connection_port

    api = ActiveMatrix::Api.new_for_domain('example.com', target: :client)

    assert_equal 'https://example.com', api.homeserver.to_s
    assert_equal 'example.com', api.connection_address
    assert_equal 8448, api.connection_port
  end

  def test_http_request_logging
    matrixsdk_add_api_stub
    api = ActiveMatrix::Api.new 'https://example.com'
    api.logger.expects(:debug?).returns(true)

    api.logger.stubs(:debug).with do |arg|
      [
        '> Sending a GET request to `https://example.com`:',
        '> accept-encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
        '> accept: */*',
        '> user-agent: Ruby',
        '>'
      ].include? arg
    end

    api.send :print_http, Net::HTTP::Get.new('https://example.com')
  end

  def test_http_response_logging
    matrixsdk_add_api_stub
    api = ActiveMatrix::Api.new 'https://example.com'
    api.logger.expects(:debug?).returns(true)

    api.logger.stubs(:debug).with do |arg|
      [
        '< Received a 200 GET response:',
        '<'
      ].include? arg
    end

    response = Net::HTTPSuccess.new(nil, 200, 'GET')
    response.instance_variable_set :@socket, nil
    api.send :print_http, response
  end

  def test_requests
    matrixsdk_add_api_stub
    Net::HTTP.any_instance.stubs(:start)

    response = Net::HTTPSuccess.new(nil, 200, 'GET')
    response.stubs(:body).returns({ user_id: '@alice:example.com' }.to_json)

    api = ActiveMatrix::Api.new 'https://example.com', threadsafe: false
    http = api.send(:http)

    http.expects(:request).returns(response)

    assert_equal({ user_id: '@alice:example.com' }, api.request(:get, :client_r0, '/account/whoami'))

    err = Net::HTTPTooManyRequests.new(nil, 200, 'GET')
    err.stubs(:body).returns({ error: { retry_after_ms: 1500 } }.to_json)
    http.expects(:request).twice.returns(err).then.returns(response)
    api.expects(:sleep).with(1.5)

    assert_equal({ user_id: '@alice:example.com' }, api.request(:get, :client_r0, '/account/whoami'))
  end

  def test_http_changes
    matrixsdk_add_api_stub
    Net::HTTP.any_instance.stubs(:start)
    Net::HTTP.any_instance.expects(:finish).never
    api = ActiveMatrix::Api.new 'https://example.com'

    api.read_timeout = 5

    assert_equal 5, api.read_timeout

    api.validate_certificate = true

    assert api.validate_certificate

    api.homeserver = URI('https://matrix.example.com')

    assert_equal 'matrix.example.com', api.homeserver.host

    http = api.send :http

    assert_equal 5, http.read_timeout
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode

    api = ActiveMatrix::Api.new 'https://example.com', threadsafe: false

    api.send(:http).expects(:finish).times(4)

    api.read_timeout = 5

    assert_equal 5, api.read_timeout

    api.validate_certificate = true

    assert api.validate_certificate

    api.homeserver = URI('https://matrix.example.com')

    assert_equal 'matrix.example.com', api.homeserver.host

    api.proxy_uri = URI('http://squid-proxy.example.com:3128')

    assert_equal 'squid-proxy.example.com', api.proxy_uri.host

    http = api.send :http

    assert_equal 'squid-proxy.example.com', http.proxy_address
  end

  class DummyError < StandardError; end

  def test_request_paths
    matrixsdk_add_api_stub
    api = ActiveMatrix::Api.new 'https://example.com'

    Net::HTTP.any_instance.stubs(:start)
    Net::HTTP.any_instance.expects(:request).with { |req| req.path == '/_matrix/client/r0/account/whoami' }.raises(DummyError)

    assert_raises(DummyError) { api.request(:get, :client_r0, '/account/whoami') }

    Net::HTTP.any_instance.expects(:request).with { |req| req.path == '/_synapse/admin/v1/account_validity/validity' }.raises(DummyError)

    assert_raises(DummyError) { api.request(:post, :admin_v1, '/account_validity/validity') }
  end
end
