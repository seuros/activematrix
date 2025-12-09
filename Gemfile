# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in matrix-sdk.gemspec
gemspec

# Allow testing against different Rails versions via ENV
rails_version = ENV['RAILS_VERSION'] || '~> 8.0'
gem 'activejob', rails_version
gem 'activerecord', rails_version
gem 'railties', rails_version

# PostgreSQL 18 required
gem 'pg', '>= 1.6'
