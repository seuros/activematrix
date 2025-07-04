# frozen_string_literal: true

require 'test_helper'

class MatrixSdkTest < ActiveSupport::TestCase
  def test_that_it_has_a_version_number
    refute_nil ::ActiveMatrix::VERSION
  end

  def test_debugging
    ::ActiveMatrix.debug!

    assert_equal 0, ::ActiveMatrix.logger.level
  end

  def test_response
    api = mock

    test1 = { a: 5, b: 6 }
    ActiveMatrix::Response.new api, test1

    assert_equal api, test1.api
    assert_equal 5, test1.a
    assert_equal 6, test1.b

    test2 = { a: 5, b: { c: 7 } }
    ActiveMatrix::Response.new api, test2

    assert_equal api, test2.api
    assert_equal 5, test2.a
    assert_equal 7, test2.b.c
  end
end
