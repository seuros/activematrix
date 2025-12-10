# frozen_string_literal: true

require 'test_helper'

class ApiCSVerificationVCRTest < ActiveSupport::TestCase
  include VCRHelper::ProtocolTests

  VCR_CASSETTE_PATH = 'api/cs_verification'

  def setup
    @api = setup_authenticated_api
  end

  def teardown
    cleanup_test_rooms(@api.client) if @api.respond_to?(:client)
  end

  # Test basic API endpoint responses
  def test_client_api_versions
    with_protocol_vcr('verification/client_api_versions') do
      versions = @api.client_api_versions

      assert_instance_of Array, versions
      assert(versions.any? { |v| v.start_with?('r0.', 'v1.') })
      assert_respond_to versions, :latest
    end
  end

  def test_allowed_login_methods
    with_protocol_vcr('verification/allowed_login_methods') do
      # Create a new non-authenticated API instance for this test
      api = ActiveMatrix::Api.new(matrix_test_server, protocols: :CS)
      methods = api.allowed_login_methods

      assert methods.key?(:flows)
      assert_kind_of Array, methods[:flows]
      assert(methods[:flows].any? { |flow| flow[:type] == 'm.login.password' })
    end
  end

  def test_login_with_password
    with_protocol_vcr('verification/login_with_password') do
      api = ActiveMatrix::Api.new(matrix_test_server, protocols: :CS)
      creds = matrix_test_credentials

      response = api.login(
        user: creds[:username],
        password: creds[:password],
        initial_device_display_name: 'ActiveMatrix VCR Test'
      )

      assert response.key?(:access_token)
      assert response.key?(:user_id)
      assert response.key?(:device_id)
      assert_equal matrix_test_user_id, response[:user_id]
    end
  end

  def test_whoami_authenticated
    with_protocol_vcr('verification/whoami_authenticated') do
      response = @api.whoami?

      assert_equal matrix_test_user_id, response[:user_id]
      assert response.key?(:device_id) if @api.device_id
    end
  end

  def test_logout
    with_protocol_vcr('verification/logout') do
      # Create a separate authenticated session to test logout
      api = ActiveMatrix::Api.new(matrix_test_server, protocols: :CS)
      creds = matrix_test_credentials

      login_response = api.login(
        user: creds[:username],
        password: creds[:password]
      )

      api.access_token = login_response[:access_token]

      # Test logout
      logout_response = api.logout

      assert_empty(logout_response)

      # Verify token is invalidated by trying whoami
      api.access_token = login_response[:access_token]
      assert_raises(ActiveMatrix::MatrixRequestError) do
        api.whoami?
      end
    end
  end

  def test_register_new_user
    with_protocol_vcr('verification/register_new_user') do
      api = ActiveMatrix::Api.new(matrix_test_server, protocols: :CS)

      # Generate unique username for test (use fixed name for VCR reproducibility)
      username = "vcr_test_user"

      response = api.register(
        username: username,
        password: 'test_password_12345',
        auth: { type: 'm.login.dummy' }
      )

      assert response.key?(:access_token)
      assert response.key?(:user_id)
      assert_includes response[:user_id], username
    end
  end

  def test_get_presence
    with_protocol_vcr('verification/get_presence') do
      response = @api.get_presence_status(matrix_test_user_id)

      assert response.key?(:presence)
      assert_includes %w[online offline unavailable], response[:presence]
    end
  end

  def test_set_presence
    with_protocol_vcr('verification/set_presence') do
      response = @api.set_presence_status(matrix_test_user_id, 'online', message: 'Testing VCR')

      assert_empty(response)
    end
  end

  def test_create_room
    with_protocol_vcr('verification/create_room') do
      response = @api.create_room(
        name: 'VCR Test Room',
        topic: 'Testing room creation with VCR',
        preset: 'private_chat'
      )

      assert response.key?(:room_id)
      assert response[:room_id].start_with?('!')

      # Clean up - leave the room
      @api.leave_room(response[:room_id])
    end
  end

  def test_join_and_leave_room
    with_protocol_vcr('verification/join_and_leave_room') do
      # Create a public room first
      room = @api.create_room(
        name: 'Join Test Room',
        preset: 'public_chat',
        visibility: 'public'
      )
      room_id = room[:room_id]

      # Leave the room we just created
      @api.leave_room(room_id)

      # Now join it back via room_id
      join_response = @api.join_room(room_id)
      assert join_response.key?(:room_id)
      assert_equal room_id, join_response[:room_id]

      # Leave again to clean up
      @api.leave_room(room_id)
    end
  end

  def test_get_room_state
    with_protocol_vcr('verification/get_room_state') do
      # Create a room first
      room_response = @api.create_room(name: 'State Test Room')
      room_id = room_response[:room_id]

      begin
        # Get all room state
        state = @api.get_room_state_all(room_id)

        assert_kind_of Array, state
        assert(state.any? { |event| event[:type] == 'm.room.create' })
        assert(state.any? { |event| event[:type] == 'm.room.member' })
      ensure
        # Clean up
        @api.leave_room(room_id)
      end
    end
  end

  def test_send_state_event
    with_protocol_vcr('verification/send_state_event') do
      # Create a room first
      room_response = @api.create_room(name: 'State Event Test Room')
      room_id = room_response[:room_id]

      begin
        # Send a state event
        response = @api.send_state_event(
          room_id,
          'm.room.topic',
          { topic: 'New topic set by VCR test' }
        )

        assert response.key?(:event_id)
      ensure
        # Clean up
        @api.leave_room(room_id)
      end
    end
  end

  def test_get_public_rooms
    with_protocol_vcr('verification/get_public_rooms') do
      response = @api.get_public_rooms(limit: 5)

      assert response.key?(:chunk)
      assert_kind_of Array, response[:chunk]
      assert response.key?(:total_room_count_estimate) || response.key?(:total_room_count)
    end
  end

  def test_get_user_profile
    with_protocol_vcr('verification/get_user_profile') do
      response = @api.get_profile(matrix_test_user_id)

      # Profile might be empty but should return a hash
      assert_kind_of Hash, response
      # May contain displayname and/or avatar_url
    end
  end

  def test_set_display_name
    with_protocol_vcr('verification/set_display_name') do
      new_name = 'VCR Test User'

      response = @api.set_display_name(matrix_test_user_id, new_name)

      assert_empty(response)

      # Verify it was set
      profile = @api.get_display_name(matrix_test_user_id)

      assert_equal 'VCR Test User', profile[:displayname]
    end
  end

  def test_get_device_list
    with_protocol_vcr('verification/get_device_list') do
      response = @api.get_devices

      assert response.key?(:devices)
      assert_kind_of Array, response[:devices]

      if response[:devices].any?
        device = response[:devices].first

        assert device.key?(:device_id)
        assert device.key?(:display_name) || device.key?(:last_seen_ts)
      end
    end
  end

  def test_sync_endpoint
    with_protocol_vcr('verification/sync_endpoint') do
      response = @api.sync(timeout: 0, filter: { room: { timeline: { limit: 1 } } }.to_json)

      assert response.key?(:next_batch)
      assert response.key?(:rooms)
      assert response.key?(:presence) || response.key?(:account_data)
    end
  end

  def test_error_responses
    # Test 404 - Non-existent endpoint
    with_protocol_vcr('verification/error_404') do
      api = ActiveMatrix::Api.new(matrix_test_server, protocols: :CS)
      api.access_token = @api.access_token

      assert_raises(ActiveMatrix::MatrixNotFoundError) do
        api.request(:get, :client_r0, '/non_existent_endpoint')
      end
    end

    # Test 401 - Unauthorized
    with_protocol_vcr('verification/error_401') do
      api = ActiveMatrix::Api.new(matrix_test_server, protocols: :CS)
      api.access_token = 'invalid_token'

      assert_raises(ActiveMatrix::MatrixNotAuthorizedError) do
        api.whoami?
      end
    end
  end
end
