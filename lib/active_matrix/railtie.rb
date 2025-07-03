# frozen_string_literal: true

require 'rails/railtie'

module ActiveMatrix
  class Railtie < Rails::Railtie
    initializer 'activematrix.configure_rails_initialization' do
      # Configure Rails.logger as the default logger
      ActiveMatrix.logger = Rails.logger
    end

    initializer 'activematrix.configure_cache' do
      # Rails cache adapter is automatically used when Rails is detected
      require 'active_matrix/util/rails_cache_adapter'
      ActiveMatrix::Util::Tinycache.adapter = ActiveMatrix::Util::RailsCacheAdapter
    end
  end
end
