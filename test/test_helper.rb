# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

if defined?(PaddedCell.coverage)
  PaddedCell.coverage(:rails) do
    skip 'lib/generators/active_matrix/install/templates/'
    formats :markdown, :lcov
  end
end

require_relative 'dummy/config/environment'
require 'rails/test_help'
require 'mocha/minitest'
require 'webmock/minitest'

WebMock.disable_net_connect!(allow_localhost: true)
