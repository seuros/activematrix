# frozen_string_literal: true

require 'rails/generators'

module ActiveMatrix
  module Generators
    class BotGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      desc 'Creates a new ActiveMatrix bot'

      argument :commands, type: :array, default: [], banner: 'command1 command2'

      check_class_collision suffix: 'Bot'

      def create_bot_file
        template 'bot.rb.erb', "app/bots/#{file_name}_bot.rb"
      end

      def create_bot_test
        template 'bot_test.rb.erb', "test/bots/#{file_name}_bot_test.rb"
      end

      def display_usage
        say "\nBot created! To use your bot:\n\n"
        say '1. Create an agent in Rails console:'
        say '   agent = ActiveMatrix::Agent.create!('
        say "     name: '#{file_name.dasherize}',"
        say "     matrix_connection: 'primary',"
        say "     bot_class: '#{class_name}Bot'"
        say '   )'
        say "\n2. Start the daemon:"
        say '   bundle exec activematrix start'
        say "\n"
      end

      private

      def file_name
        @_file_name ||= remove_possible_suffix(super)
      end

      def remove_possible_suffix(name)
        name.sub(/_?bot$/i, '')
      end
    end
  end
end
