# frozen_string_literal: true

require 'test_helper'

class ApiCSProtocolVCRTest < ActiveSupport::TestCase
  include VCRHelper::ProtocolTests

  VCR_CASSETTE_PATH = 'api/cs_protocol'

  def setup
    @api = setup_authenticated_api
  end

  def teardown
    cleanup_test_rooms(@api.client) if @api.respond_to?(:client)
  end

  def test_api_versions
    with_protocol_vcr('api_versions') do
      versions = @api.client_api_versions

      assert_instance_of Array, versions
      assert(versions.any? { |v| v.start_with?('r0.', 'v1.') })
      assert_respond_to versions, :latest
      assert versions.latest
    end
  end

  def test_api_unstable_features
    with_protocol_vcr('unstable_features') do
      features = @api.client_api_unstable_features

      assert_instance_of Hash, features
      assert_respond_to features, :has?
    end
  end

  def test_whoami
    with_protocol_vcr('whoami') do
      response = @api.whoami?

      assert_equal matrix_test_user_id, response[:user_id]
    end
  end

  def test_sync
    with_protocol_vcr('sync_basic') do
      response = @api.sync(timeout: 1) # Short timeout for testing

      assert response.key?(:next_batch)
      assert response.key?(:rooms)
    end
  end

  def test_sync_timeout
    with_protocol_vcr('sync_with_timeout') do
      response = @api.sync(timeout: 3)

      assert response.key?(:next_batch)
    end

    with_protocol_vcr('sync_no_timeout') do
      response = @api.sync(timeout: nil)

      assert response.key?(:next_batch)
    end
  end

  def test_send_message
    skip 'Requires a test room - implement room creation first'
  end

  def test_send_emote
    skip 'Requires a test room - implement room creation first'
  end

  def test_public_rooms
    with_protocol_vcr('public_rooms') do
      response = @api.get_public_rooms(limit: 10)

      assert response.key?(:chunk)
      assert_instance_of Array, response[:chunk]
    end
  end

  def test_get_room_state
    skip 'Requires a test room - implement room creation first'
  end

  def test_download_url
    # This test doesn't require actual API calls
    # Get the base URL from the current api instance
    base_url = @api.homeserver.to_s.chomp('/')

    assert_equal "#{base_url}/_matrix/media/r0/download/example.com/media",
                 @api.get_download_url('mxc://example.com/media').to_s
    assert_equal 'https://matrix.org/_matrix/media/r0/download/example.com/media',
                 @api.get_download_url('mxc://example.com/media', source: 'matrix.org').to_s
  end
end
