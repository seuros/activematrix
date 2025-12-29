# frozen_string_literal: true

require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TheSource
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    # Dummy app is nested inside engine - add engine migrations directly
    config.paths['db/migrate'] << File.expand_path('../../../../db/migrate', __FILE__)
  end
end
