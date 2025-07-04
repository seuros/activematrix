# frozen_string_literal: true

require 'test_helper'

class ApiCSProtocolVCRTest < ActiveSupport::TestCase
  include VCRHelper::ProtocolTests
  
  def setup
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      @api = setup_authenticated_api
    else
      # Fall back to mock setup for backward compatibility
      @http = mock
      @http.stubs(:active?).returns(true)
      
      @api = ActiveMatrix::Api.new 'https://example.com', protocols: :CS, threadsafe: false
      @api.instance_variable_set :@http, @http
      @api.stubs(:print_http)
      
      matrixsdk_add_api_stub
    end
  end

  def teardown
    cleanup_test_rooms(@api.client) if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true' && @api.respond_to?(:client)
  end

  def mock_success(body)
    response = mock
    response.stubs(:is_a?).with(Net::HTTPTooManyRequests).returns(false)
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    response.stubs(:body).returns(body)
    response
  end

  def test_api_versions
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      with_protocol_vcr('api_versions') do
        versions = @api.client_api_versions
        assert_includes versions.versions, 'r0.6.1'
        assert versions.latest
      end
    else
      @http.expects(:request).returns(mock_success('{"versions":["r0.3.0","r0.4.0"]}'))
      assert_equal 'r0.4.0', @api.client_api_versions.latest
    end
  end

  def test_api_unstable_features
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      with_protocol_vcr('unstable_features') do
        features = @api.client_api_unstable_features
        assert_instance_of Hash, features.features
      end
    else
      @http.expects(:request).returns(mock_success('{"unstable_features":{"lazy_loading_members": true}}'))
      assert @api.client_api_unstable_features.has?(:lazy_loading_members)
    end
  end

  def test_whoami
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      with_protocol_vcr('whoami') do
        response = @api.whoami?
        assert_equal matrix_test_user_id, response[:user_id]
      end
    else
      @http.expects(:request).returns(mock_success('{"user_id":"@user:example.com"}'))
      assert_equal({ user_id: '@user:example.com' }, @api.whoami?)
    end
  end

  def test_sync
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      with_protocol_vcr('sync_basic') do
        response = @api.sync(timeout: 1) # Short timeout for testing
        assert response.key?(:next_batch)
        assert response.key?(:rooms)
      end
    else
      @http.expects(:request).with do |req|
        req.path == '/_matrix/client/r0/sync?timeout=30000'
      end.returns(mock_success('{}'))
      assert @api.sync
    end
  end

  def test_sync_timeout
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      with_protocol_vcr('sync_with_timeout') do
        response = @api.sync(timeout: 3)
        assert response.key?(:next_batch)
      end
      
      with_protocol_vcr('sync_no_timeout') do
        response = @api.sync(timeout: nil)
        assert response.key?(:next_batch)
      end
    else
      @http.expects(:request).with do |req|
        req.path == '/_matrix/client/r0/sync?timeout=3000'
      end.returns(mock_success('{}'))
      assert @api.sync(timeout: 3)

      @http.expects(:request).with do |req|
        req.path == '/_matrix/client/r0/sync'
      end.returns(mock_success('{}'))
      assert @api.sync(timeout: nil)
    end
  end

  def test_send_message
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      skip 'Requires a test room - implement room creation first'
    else
      @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/send/m.room.message/42', body: { msgtype: 'm.text', body: 'this is a message' }, query: {}).returns({})
      assert @api.send_message('!room:example.com', 'this is a message', txn_id: 42)
    end
  end

  def test_send_emote
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      skip 'Requires a test room - implement room creation first'
    else
      @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/send/m.room.message/42', body: { msgtype: 'm.emote', body: 'this is an emote' }, query: {}).returns({})
      assert @api.send_emote('!room:example.com', 'this is an emote', txn_id: 42)
    end
  end

  def test_public_rooms
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      with_protocol_vcr('public_rooms') do
        response = @api.get_public_rooms(limit: 10)
        assert response.key?(:chunk)
        assert_instance_of Array, response[:chunk]
      end
    else
      skip 'Mock test not implemented for public_rooms'
    end
  end

  def test_get_room_state
    if ENV['USE_VCR_FOR_PROTOCOL_TESTS'] == 'true'
      skip 'Requires a test room - implement room creation first'
    else
      skip 'Mock test not implemented for room state'
    end
  end

  def test_download_url
    # This test doesn't require actual API calls
    assert_equal 'https://example.com/_matrix/media/r0/download/example.com/media', 
                 @api.get_download_url('mxc://example.com/media').to_s
    assert_equal 'https://matrix.org/_matrix/media/r0/download/example.com/media', 
                 @api.get_download_url('mxc://example.com/media', source: 'matrix.org').to_s
  end
end