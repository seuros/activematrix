# frozen_string_literal: true

require 'rails/generators'

module ActiveMatrix
  module Generators
    # Sets an app up for ActiveMatrix: migrations, the delivery endpoint, an
    # ApplicationBot, and the daemon's configuration file.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Installs ActiveMatrix: migrations, the delivery route, ApplicationBot and config/activematrixd.toml'

      class_option :skip_migrations, type: :boolean, default: false, desc: 'Do not copy the migrations'

      def copy_migrations
        rails_command 'active_matrix:install:migrations', inline: true unless options[:skip_migrations]
      end

      def create_initializer
        template 'active_matrix.rb.tt', 'config/initializers/active_matrix.rb'
      end

      def mount_engine
        route "mount ActiveMatrix::Engine, at: '/active_matrix'"
      end

      def create_application_bot
        template 'application_bot.rb.tt', 'app/bots/application_bot.rb'
      end

      def create_daemon_config
        template 'activematrixd.toml.tt', 'config/activematrixd.toml'
      end

      def show_next_steps
        readme 'NEXT_STEPS' if behavior == :invoke
      end
    end
  end
end
