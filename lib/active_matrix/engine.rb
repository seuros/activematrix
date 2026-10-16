# frozen_string_literal: true

require 'rails/engine'
# The engine serves the delivery endpoint.
require 'action_controller/railtie'

module ActiveMatrix
  class Engine < Rails::Engine
    isolate_namespace ActiveMatrix
    engine_name 'active_matrix'

    initializer 'active_matrix.log_subscriber' do
      ActiveMatrix::LogSubscriber.attach_to :active_matrix
    end
  end
end
