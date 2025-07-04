# frozen_string_literal: true

require 'rails/engine'

module ActiveMatrix
  class Engine < Rails::Engine
    engine_name 'activematrix'

    initializer 'activematrix.configure_logger' do
      # Configure logger
      ActiveMatrix.logger = Rails.logger
    end
  end
end
