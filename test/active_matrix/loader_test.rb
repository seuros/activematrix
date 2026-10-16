# frozen_string_literal: true

require 'test_helper'

class LoaderTest < ActiveSupport::TestCase
  test 'the gem eager loads' do
    assert_nothing_raised { ActiveMatrix::Loader.eager_load(force: true) }
  end

  test 'the engine eager loads' do
    assert_nothing_raised { Rails.application.eager_load! }
  end
end
