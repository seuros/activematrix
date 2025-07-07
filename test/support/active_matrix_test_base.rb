# frozen_string_literal: true

# Extend ActiveSupport::TestCase with cache clearing and test helpers
class ActiveSupport::TestCase
  # Include ActiveRecord test fixtures support
  include ActiveRecord::TestFixtures

  # Override setup to clear cache before each test
  def setup
    # Clear Rails cache if it exists
    Rails.cache.clear

    cache_dir = File.expand_path('../../tmp/cache/test', __dir__)
    # Completely remove and recreate the cache directory
    FileUtils.rm_rf(cache_dir)
    FileUtils.mkdir_p(cache_dir)

    # Clear any pre-populated room members
    @room.instance_variable_set(:@pre_populated_members, nil) if defined?(@room)

    super
  end

  # Helper methods available to all tests
  def matrixsdk_add_api_stub
    ActiveMatrix::Api
      .any_instance
      .stubs(:client_api_latest)
      .returns(:client_v3)
  end

  def expect_message(object, message, *)
    object.expects(message).with(*)
  end

  # Use transactional fixtures by default
  self.use_transactional_tests = true

  # Include VCR helpers after they're defined
  include VCRHelper
end
