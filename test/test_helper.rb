# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/vendor/'
end

# Configure Rails environment for testing
ENV['RAILS_ENV'] = 'test'
require_relative 'dummy/config/environment'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'active_matrix'

require 'maxitest/autorun'
require 'active_support'
require 'active_support/test_case'
require 'active_support/core_ext/time/zones'
require 'mocha/minitest'
require 'vcr'
require 'webmock/minitest'
require 'uri'
require_relative 'support/vcr_helper'
require_relative 'support/active_matrix_test_base'
require_relative 'support/faraday_test_helper'

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

# Disable network connections by default for test safety
# VCR will handle allowing connections when recording cassettes
WebMock.disable_net_connect!(
  allow_localhost: true, # Allow connections to localhost for test servers
  allow: 'chromedriver.storage.googleapis.com' # Allow chromedriver downloads if needed
)

# VCR helper methods for backwards compatibility
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

# Temporarily disable VCR for a block and allow real network connections
# Use sparingly - prefer VCR cassettes for reproducible tests
def without_vcr(&)
  was_disabled = WebMock.net_connect_allowed?
  WebMock.allow_net_connect!
  VCR.turned_off(&)
ensure
  WebMock.disable_net_connect!(allow_localhost: true) unless was_disabled
end
