# frozen_string_literal: true

require_relative 'boot'

require 'rails'
require 'active_record/railtie'
require 'active_job/railtie'
require 'action_controller/railtie'

Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path('..', __dir__)
    config.eager_load = false
    config.logger = ActiveSupport::Logger.new(File::NULL)
    config.secret_key_base = 'dummy'
    config.cache_store = :memory_store
    config.active_job.queue_adapter = :test
    config.paths['db/migrate'] << File.expand_path('../../../db/migrate', __dir__)
  end
end
