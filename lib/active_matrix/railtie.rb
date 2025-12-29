# frozen_string_literal: true

require 'rails/railtie'

module ActiveMatrix
  class Railtie < Rails::Railtie
    initializer 'active_matrix.configure_rails_initialization' do
      Rails.logger.debug 'ActiveMatrix::Railtie: Initializer running'
      ActiveMatrix.logger = Rails.logger
    end

    # Load connection config after application initializers run
    # This ensures user's initializer can set config.default_connection
    config.after_initialize do
      config_path = Rails.root.join('config/active_matrix.yml')

      if File.exist?(config_path)
        Rails.logger.debug 'ActiveMatrix::Railtie: Loading connection config'
        ActiveMatrix::ConnectionRegistry.instance.load!(config_path)
      else
        Rails.logger.debug 'ActiveMatrix::Railtie: No config/active_matrix.yml found'
      end
    end
  end
end
