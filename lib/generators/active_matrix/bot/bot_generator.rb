# frozen_string_literal: true

require 'rails/generators'

module ActiveMatrix
  module Generators
    # A bot and its test: rails g active_matrix:bot greeter ping status
    class BotGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      desc 'Creates a bot in app/bots and its test in test/bots'

      argument :commands, type: :array, default: [], banner: 'command command'

      check_class_collision suffix: 'Bot'

      def create_bot
        template 'bot.rb.tt', "app/bots/#{bot_file_name}.rb"
      end

      def create_test
        template 'bot_test.rb.tt', "test/bots/#{bot_file_name}_test.rb"
      end

      private

      # `greeter`, `greeter_bot` and `GreeterBot` all make GreeterBot.
      def bot_name = file_name.delete_suffix('_bot')
      def bot_file_name = "#{bot_name}_bot"
      def bot_class_name = "#{bot_name.camelize}Bot"
      def command_names = commands.presence || ['ping']
    end
  end
end
