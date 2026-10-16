# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'rake'

group :development, :test do
  # System tests serve the dummy app with shuttlebay, behind guardship's mothership.
  gem 'guardship', require: false
  gem 'minitest', '~> 6.0'
  gem 'mocha', '~> 3.0', require: false
  gem 'padded_cell', require: false
  gem 'rails_lens', require: false
  gem 'shuttlebay', require: false
  gem 'webmock', require: false
end
