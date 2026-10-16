# frozen_string_literal: true

require 'test_helper'
require 'generators/active_matrix/install/install_generator'

class InstallGeneratorTest < Rails::Generators::TestCase
  tests ActiveMatrix::Generators::InstallGenerator
  destination File.expand_path('../../tmp/generators/install', __dir__)

  setup do
    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, 'config'))
    File.write(File.join(destination_root, 'config/routes.rb'), "Rails.application.routes.draw do\nend\n")
  end

  test 'mounts the engine and writes the app-side files' do
    run_generator %w[--skip-migrations]

    assert_file 'config/routes.rb', %r{mount ActiveMatrix::Engine, at: '/active_matrix'}
    assert_file 'app/bots/application_bot.rb', /class ApplicationBot < ActiveMatrix::Bot::Base/
    assert_file 'config/activematrixd.toml', %r{delivery_url = "http://localhost:3000/active_matrix/deliveries"}
    assert_file 'config/initializers/active_matrix.rb' do |initializer|
      assert_match "ENV.fetch('ACTIVEMATRIX_DELIVERY_SECRET', nil)", initializer
      assert_no_match(/start|AgentManager/, initializer, 'nothing starts agents from the web process')
    end
  end

  test 'secrets in the environment never reach the generated files' do
    ENV['ACTIVEMATRIX_DELIVERY_SECRET'] = 'must-not-leak'
    run_generator %w[--skip-migrations]

    %w[config/initializers/active_matrix.rb config/activematrixd.toml].each do |file|
      assert_file(file) { assert_no_match(/must-not-leak/, it) }
    end
  ensure
    ENV.delete('ACTIVEMATRIX_DELIVERY_SECRET')
  end

  test 'the generated toml is something the daemon accepts' do
    run_generator %w[--skip-migrations]

    assert_file 'config/activematrixd.toml' do |toml|
      keys = toml.lines.grep(/\A\w+ =/).map { it.split(' =').first }

      assert_equal %w[delivery_url probe_bind max_agents heartbeat_secs lease_ttl_secs shutdown_timeout_secs], keys
    end
  end
end
