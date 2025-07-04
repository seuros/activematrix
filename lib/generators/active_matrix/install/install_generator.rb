# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module ActiveMatrix
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates ActiveMatrix migrations and initializers'

      def create_migrations
        migration_template 'create_matrix_agents.rb', 'db/migrate/create_matrix_agents.rb'
        migration_template 'create_agent_memories.rb', 'db/migrate/create_agent_memories.rb'
        migration_template 'create_conversation_contexts.rb', 'db/migrate/create_conversation_contexts.rb'
        migration_template 'create_global_memories.rb', 'db/migrate/create_global_memories.rb'
      end

      def create_initializer
        template 'active_matrix.rb', 'config/initializers/active_matrix.rb'
      end

      def display_post_install
        readme 'README' if behavior == :invoke
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
