# frozen_string_literal: true

require 'test_helper'
require 'generators/active_matrix/bot/bot_generator'

class BotGeneratorTest < Rails::Generators::TestCase
  tests ActiveMatrix::Generators::BotGenerator
  destination File.expand_path('../../tmp/generators/bot', __dir__)
  setup :prepare_destination

  test 'a bot with its commands and a test for each' do
    run_generator %w[greeter ping status]

    assert_file 'app/bots/greeter_bot.rb' do |bot|
      assert_match(/class GreeterBot < ApplicationBot/, bot)
      assert_match(/command :ping, 'Ping' do\n    reply 'pong'/, bot)
      assert_match(/command :status/, bot)
    end
    assert_file 'test/bots/greeter_bot_test.rb', /include ActiveMatrix::Testing/, /deliver_message\(@agent, '!status'\)/
  end

  test 'a Bot suffix is not doubled' do
    run_generator %w[GreeterBot]

    assert_file 'app/bots/greeter_bot.rb', /class GreeterBot < ApplicationBot/
    assert_no_file 'app/bots/greeter_bot_bot.rb'
  end

  test 'the generated bot and test run' do
    run_generator %w[sample ping]
    Object.send(:remove_const, :SampleBot) if defined?(SampleBot)
    load File.join(destination_root, 'app/bots/sample_bot.rb')
    agent = ActiveMatrix::Agent.create!(name: 'sample', bot_class: 'SampleBot', homeserver_url: 'https://matrix.test')
    extend ActiveMatrix::Testing

    deliver_message(agent, '!ping')

    assert_replied agent, 'pong'
  end
end
