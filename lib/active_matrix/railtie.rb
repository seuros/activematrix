# frozen_string_literal: true

require 'rails/railtie'

module ActiveMatrix
  class Railtie < Rails::Railtie
    initializer 'activematrix.configure_rails_initialization' do
      # Configure Rails.logger as the default logger
      ActiveMatrix.logger = Rails.logger
    end
  end
end
