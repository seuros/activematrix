# frozen_string_literal: true

require 'rails/generators'

module ActiveMatrix
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Installs ActiveMatrix configuration and copies migrations'

      def copy_migrations
        rails_command 'active_matrix:install:migrations', inline: true
      end

      def create_connection_config
        template 'active_matrix.yml', 'config/active_matrix.yml'
      end

      def create_initializer
        template 'active_matrix.rb', 'config/initializers/active_matrix.rb'
      end

      def display_post_install
        readme 'README' if behavior == :invoke
      end
    end
  end
end
