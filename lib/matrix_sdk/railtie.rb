# frozen_string_literal: true

require 'rails/railtie'

module MatrixSdk
  class Railtie < Rails::Railtie
    initializer 'activematrix.configure_rails_initialization' do
      # Configure Rails.logger as the default logger
      MatrixSdk.logger = Rails.logger
    end

    initializer 'activematrix.configure_cache' do
      # Rails cache adapter is automatically used when Rails is detected
      require 'matrix_sdk/util/rails_cache_adapter'
      MatrixSdk::Util::Tinycache.adapter = MatrixSdk::Util::RailsCacheAdapter
    end
  end
end