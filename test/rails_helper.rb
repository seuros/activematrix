# frozen_string_literal: true

# This file is for Rails-specific tests like generators and migrations
ENV['RAILS_ENV'] ||= 'test'
require_relative 'test_helper'

# Load Rails testing support
require 'rails/test_help'

# Ensure database is migrated
ActiveRecord::Migrator.migrations_paths = [File.expand_path('dummy/db/migrate', __dir__)]

class Rails::TestCase < ActiveSupport::TestCase
  # Add Rails-specific test helpers here
end
