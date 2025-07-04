# frozen_string_literal: true

require 'test_helper'

class ResponseTest < ActiveSupport::TestCase
  def setup
    @http = mock
    @http.stubs(:active?).returns(true)

    @api = ActiveMatrix::Api.new 'https://example.com'
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)
  end

  def test_creation
    data = { test_key: 'value' }
    response = ActiveMatrix::Response.new(@api, data)

    assert_equal @api, response.api
    assert_equal 'value', response.test_key
  end

  def test_creation_failure
    data = 'Something else'
    assert_raises(ArgumentError) { ActiveMatrix::Response.new(@api, data) }
  end
end
