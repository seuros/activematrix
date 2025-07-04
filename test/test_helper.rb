# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/vendor/'
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'active_matrix'

require 'active_support'
require 'active_support/test_case'
require 'active_support/testing/autorun'
require 'mocha/minitest'
require 'vcr'
require 'webmock/minitest'
require 'uri'
require_relative 'support/vcr_helper'

# Configure VCR
VCR.configure do |config|
  config.cassette_library_dir = 'test/fixtures/vcr_cassettes'
  config.hook_into :webmock
  config.default_cassette_options = {
    record: ENV.fetch('VCR_MODE', :once).to_sym,
    match_requests_on: %i[method uri body]
  }

  # Filter sensitive data
  config.filter_sensitive_data('<ACCESS_TOKEN>') do |interaction|
    interaction.request.headers['Authorization']&.first&.gsub(/Bearer .+/, 'Bearer <ACCESS_TOKEN>')
  end

  config.filter_sensitive_data('<PASSWORD>') do |interaction|
    JSON.parse(interaction.request.body)['password'] rescue nil if interaction.request.body&.include?('password')
  end

  config.filter_sensitive_data('<MATRIX_SERVER>') { ENV.fetch('MATRIX_TEST_SERVER', 'https://arena.seuros.net') }
  config.filter_sensitive_data('<TEST_USER>') { ENV.fetch('MATRIX_TEST_USER', 'testuser') }

  # Allow connections to localhost for non-VCR tests
  config.allow_http_connections_when_no_cassette = true
end

# Disable WebMock by default, enable it only for VCR tests
WebMock.allow_net_connect!

# Set up a test cache for Rails.cache
require 'active_support/cache'
require 'fileutils'

module Rails
  class << self
    def cache
      @cache ||= begin
        cache_dir = File.expand_path('../tmp/cache/test', __dir__)
        FileUtils.mkdir_p(cache_dir)
        ActiveSupport::Cache::FileStore.new(cache_dir, expires_in: 1.hour)
      end
    end
  end
end

def expect_message(object, message, *)
  object.expects(message).with(*)
end

class ActiveSupport::TestCase
  # Add Rails test helpers
  include ActiveSupport::Testing::Assertions

  def setup
    # More robust cache clearing
    if defined?(Rails) && Rails.respond_to?(:cache)
      Rails.cache.clear
      cache_dir = File.expand_path('../tmp/cache/test', __dir__)
      # Completely remove and recreate the cache directory
      FileUtils.rm_rf(cache_dir)
      FileUtils.mkdir_p(cache_dir)
      # Force Rails to create a new cache instance
      Rails.instance_variable_set(:@cache, nil)
    end
    super
  end

  def matrixsdk_add_api_stub
    ActiveMatrix::Api
      .any_instance
      .stubs(:client_api_latest)
      .returns(:client_r0)
  end

  # VCR helper methods
  def with_vcr_cassette(name = nil, options = {}, &)
    name ||= "#{self.class.name.gsub('::', '/')}/#{method_name}"
    VCR.use_cassette(name, options, &)
  end

  def vcr_mode
    ENV.fetch('VCR_MODE', 'once').to_sym
  end

  def use_real_matrix_server?
    ENV['USE_REAL_SERVER'] == 'true' || vcr_mode == :record
  end

  def matrix_test_server
    ENV.fetch('MATRIX_TEST_SERVER', 'https://arena.seuros.net')
  end

  def matrix_test_credentials
    {
      server: matrix_test_server,
      username: ENV.fetch('MATRIX_TEST_USER', 'testuser'),
      password: ENV.fetch('MATRIX_TEST_PASSWORD', 'testuser12345678')
    }
  end

  def matrix_test_user_id
    "@#{matrix_test_credentials[:username]}:#{URI.parse(matrix_test_server).host}"
  end

  # Temporarily disable VCR for a block
  def without_vcr(&)
    WebMock.allow_net_connect!
    VCR.turned_off(&)
  ensure
    WebMock.disable_net_connect! if VCR.current_cassette
  end

  # Use transactional fixtures by default
  self.use_transactional_tests = true if respond_to?(:use_transactional_tests=)
end
