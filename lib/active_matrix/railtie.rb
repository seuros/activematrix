# frozen_string_literal: true

require 'rails/railtie'

module ActiveMatrix
  class Railtie < Rails::Railtie
    Rails.logger.debug 'ActiveMatrix::Railtie: Loading...'

    initializer 'activematrix.configure_rails_initialization' do
      Rails.logger.debug 'ActiveMatrix::Railtie: Initializer running'
      # Configure Rails.logger as the default logger
      ActiveMatrix.logger = Rails.logger
      Rails.logger.debug 'ActiveMatrix::Railtie: Logger configured'

      # Debug autoload paths
      Rails.logger.debug { "ActiveMatrix::Railtie: Autoload paths = #{Rails.application.config.autoload_paths}" }
      Rails.logger.debug { "ActiveMatrix::Railtie: Eager load paths = #{Rails.application.config.eager_load_paths}" }
    end
  end
end
