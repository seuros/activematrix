# frozen_string_literal: true

require 'rails/engine'

module ActiveMatrix
  class Engine < Rails::Engine
    engine_name 'activematrix'

    initializer 'activematrix.configure_logger' do
      ActiveMatrix.logger = Rails.logger
    end

    initializer 'activematrix.initialize_metrics', after: 'activematrix.configure_logger' do
      # Eagerly initialize Metrics singleton to subscribe to notifications
      ActiveMatrix::Metrics.instance
    end
  end
end
