# frozen_string_literal: true

require 'rails/engine'

module ActiveMatrix
  class Engine < Rails::Engine
    engine_name 'active_matrix'

    initializer 'active_matrix.configure_logger' do
      ActiveMatrix.logger = Rails.logger
    end

    initializer 'active_matrix.initialize_metrics', after: 'active_matrix.configure_logger' do
      ActiveMatrix::Metrics.instance
    end

    config.after_initialize do
      config_path = Rails.root.join('config/active_matrix.yml')
      if File.exist?(config_path)
        ActiveMatrix::ConnectionRegistry.instance.load!(config_path)
      end
    end
  end
end
