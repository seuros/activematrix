# frozen_string_literal: true

require_relative 'test_helper'

class VCRIntegrationTest < ActiveSupport::TestCase
  def test_vcr_basic_functionality
    # Test that VCR is properly configured
    assert VCR.configuration.cassette_library_dir.end_with?('test/fixtures/vcr_cassettes')
    # VCR is configured with webmock hook in test_helper.rb
    assert_not_nil VCR.configuration
  end

  def test_login_with_vcr
    skip 'Skipping VCR test - set USE_REAL_SERVER=true to run' unless ENV['RUN_VCR_TESTS']

    with_vcr_cassette('integration/login') do
      creds = matrix_test_credentials
      api = ActiveMatrix::Api.new(creds[:server])

      response = api.login(
        user: creds[:username],
        password: creds[:password]
      )

      assert response.key?(:access_token)
      assert response.key?(:user_id)
      assert_equal matrix_test_user_id, response[:user_id]
    end
  end

  def test_whoami_with_vcr
    skip 'Skipping VCR test - set USE_REAL_SERVER=true to run' unless ENV['RUN_VCR_TESTS']

    client = create_vcr_client(cassette_prefix: 'integration')

    with_vcr_cassette('integration/whoami') do
      response = client.api.whoami

      assert_equal matrix_test_user_id, response[:user_id]
    end
  end

  def test_public_rooms_with_vcr
    skip 'Skipping VCR test - set USE_REAL_SERVER=true to run' unless ENV['RUN_VCR_TESTS']

    with_vcr_cassette('integration/public_rooms') do
      api = ActiveMatrix::Api.new(matrix_test_server)
      response = api.get_public_rooms

      assert response.key?(:chunk)
      assert_kind_of Array, response[:chunk]
    end
  end
end
