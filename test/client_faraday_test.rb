# frozen_string_literal: true

require 'test_helper'
require 'support/faraday_test_helper'

class ClientFaradayTest < ActiveSupport::TestCase
  include FaradayTestHelper

  def setup
    super
    setup_faraday_stubs
  end

  def test_creation
    client = ActiveMatrix::Client.new 'https://example.com'

    assert_not client.api.nil?
    assert_equal client.api.homeserver, URI('https://example.com')
  end

  def test_login
    cl = ActiveMatrix::Client.new 'https://example.com'

    # Set up Faraday stubs
    stub_http_client(cl.api)

    # Stub login request
    @faraday_stubs.post('/_matrix/client/v3/login') do |env|
      req_body = JSON.parse(env.body, symbolize_names: true)
      if req_body[:user] == 'alice' && req_body[:password] == 'password'
        [200, { 'Content-Type' => 'application/json' },
         { user_id: '@alice:example.com', access_token: 'opaque', device_id: 'device', home_server: 'example.com' }.to_json]
      else
        [403, { 'Content-Type' => 'application/json' },
         { errcode: 'M_FORBIDDEN', error: 'Invalid credentials' }.to_json]
      end
    end

    # Stub sync request - cl.expects(:sync) means sync will be called
    @faraday_stubs.get('/_matrix/client/v3/sync') do
      [200, { 'Content-Type' => 'application/json' },
       { presence: { events: [] }, rooms: { invite: [], leave: [], join: [] }, next_batch: 's1' }.to_json]
    end

    cl.login('alice', 'password')

    assert_predicate cl, :logged_in?
    assert_equal '@alice:example.com', cl.mxid.to_s

    # Stub logout
    @faraday_stubs.post('/_matrix/client/v3/logout') do
      [200, { 'Content-Type' => 'application/json' }, {}.to_json]
    end

    cl.logout

    assert_not cl.logged_in?
    assert_not_equal '@alice:example.com', cl.mxid.to_s

    verify_faraday_stubs
  end

  def test_account_data
    cl = ActiveMatrix::Client.new 'https://example.com', user_id: '@alice:example.com'

    # Set up Faraday stubs
    stub_http_client(cl.api)

    # Stub successful account data request - note the URL encoding
    @faraday_stubs.get('/_matrix/client/v3/user/%40alice%3Aexample.com/account_data/example_key') do
      [200, { 'Content-Type' => 'application/json' }, { hello: 'world' }.to_json]
    end

    # Stub 404 response
    @faraday_stubs.get('/_matrix/client/v3/user/%40alice%3Aexample.com/account_data/example_key_2') do
      [404, { 'Content-Type' => 'application/json' },
       { errcode: 'M_NOT_FOUND', error: 'Not found' }.to_json]
    end

    assert_equal({ hello: 'world' }, cl.account_data['example_key'])
    assert_equal({ hello: 'world' }, cl.account_data['example_key']) # Uses cache
    assert_empty(cl.account_data[:example_key_2])

    # Stub set account data
    @faraday_stubs.put('/_matrix/client/v3/user/%40alice%3Aexample.com/account_data/example_key') do |env|
      req_body = JSON.parse(env.body, symbolize_names: true)

      assert_equal({ hello: 'test' }, req_body)
      [200, { 'Content-Type' => 'application/json' }, {}.to_json]
    end

    cl.account_data['example_key'] = { hello: 'test' }

    assert_equal({ hello: 'test' }, cl.account_data['example_key'])

    verify_faraday_stubs
  end

  def test_public_rooms
    cl = ActiveMatrix::Client.new 'https://example.com'
    stub_http_client(cl.api)

    # Stub the actual public rooms request - v3 version
    public_rooms_response = {
      chunk: [
        { room_id: '!room1:example.com', name: 'Room 1' },
        { room_id: '!room2:example.com', name: 'Room 2' }
      ],
      next_batch: nil, # Set to nil to avoid pagination
      prev_batch: nil,
      total_room_count_estimate: 2
    }.to_json

    @faraday_stubs.get('/_matrix/client/v3/publicRooms') do
      [200, { 'Content-Type' => 'application/json' }, public_rooms_response]
    end

    # Stub room state requests for name
    @faraday_stubs.get('/_matrix/client/v3/rooms/%21room1%3Aexample.com/state/m.room.name') do
      [200, { 'Content-Type' => 'application/json' }, { name: 'Room 1' }.to_json]
    end

    public_rooms = cl.public_rooms

    assert_equal 2, public_rooms.size
    assert_equal 'Room 1', public_rooms.first.name

    # Test with server parameter - v3 version only
    @faraday_stubs.get('/_matrix/client/v3/publicRooms?server=matrix.org') do
      [200, { 'Content-Type' => 'application/json' },
       { chunk: [], next_batch: nil, prev_batch: nil }.to_json]
    end

    public_rooms = cl.public_rooms(server: 'matrix.org')

    assert_empty public_rooms

    verify_faraday_stubs
  end
end
