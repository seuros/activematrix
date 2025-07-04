# frozen_string_literal: true

require 'rails/generators'

module ActiveMatrix
  module Generators
    class BotGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      desc 'Creates a new ActiveMatrix bot'

      argument :commands, type: :array, default: [], banner: 'command1 command2'

      def create_bot_file
        template 'bot.rb.erb', "app/bots/#{file_name}_bot.rb"
      end

      def create_bot_spec
        template 'bot_spec.rb.erb', "spec/bots/#{file_name}_bot_spec.rb"
      end

      def display_usage
        say "\nBot created! To use your bot:\n\n"
        say '1. Create an agent in Rails console:'
        say '   agent = MatrixAgent.create!('
        say "     name: '#{file_name}',"
        say "     homeserver: 'https://matrix.org',"
        say "     username: 'your_bot_username',"
        say "     password: 'your_bot_password',"
        say "     bot_class: '#{class_name}Bot'"
        say '   )'
        say "\n2. Start the agent:"
        say '   ActiveMatrix::AgentManager.instance.start_agent(agent)'
        say "\n"
      end
    end
  end
end
