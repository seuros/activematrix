# frozen_string_literal: true

require 'rails/railtie'

module ActiveMatrix
  class Railtie < Rails::Railtie
    # Add the app directory to Rails' autoload paths
    config.autoload_paths += Dir[File.expand_path('../../../app/**/*', __FILE__)]
    
    initializer 'activematrix.configure_rails_initialization' do
      # Configure Rails.logger as the default logger
      ActiveMatrix.logger = Rails.logger
    end
    
    # Load models when Rails loads
    initializer 'activematrix.load_models', before: :load_config_initializers do |app|
      app.config.paths.add 'app/models', glob: '**/*.rb'
      
      # Ensure models are loaded
      models_path = File.expand_path('../../../app/models', __FILE__)
      if File.directory?(models_path)
        Dir[File.join(models_path, '**', '*.rb')].each do |file|
          require_dependency file
        end
      end
    end
  end
end
