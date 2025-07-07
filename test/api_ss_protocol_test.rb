# frozen_string_literal: true

require 'test_helper'

class ApiSSTest < ActiveSupport::TestCase
  include FaradayTestHelper

  def setup
    setup_faraday_stubs

    @api = ActiveMatrix::Api.new 'https://example.com', protocols: :SS, threadsafe: false
    stub_http_client(@api)
  end

  def test_api_server_version
    stub_faraday_request(:get, '/_matrix/federation/v1/version',
                         { server: { name: 'Synapse', version: '0.99.5.2' } })

    assert_equal 'Synapse 0.99.5.2', @api.server_version.to_s
    verify_faraday_stubs
  end
end
