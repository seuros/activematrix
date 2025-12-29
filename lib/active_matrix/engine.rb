# frozen_string_literal: true

require 'rails/engine'

module ActiveMatrix
  class Engine < Rails::Engine
    engine_name 'active_matrix'

    initializer 'active_matrix.configure_logger' do
      ActiveMatrix.logger = Rails.logger
    end

    initializer 'active_matrix.initialize_metrics', after: 'active_matrix.configure_logger' do
      # Eagerly initialize Metrics singleton to subscribe to notifications
      ActiveMatrix::Metrics.instance
    end
  end
end
