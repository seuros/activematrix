# frozen_string_literal: true

require 'test_helper'

class AgentTest < ActiveSupport::TestCase
  test 'a new agent is enabled, offline and not logged in' do
    agent = create_agent

    assert_predicate agent, :enabled?
    assert_predicate agent, :offline?
    assert_not agent.logged_in?
    assert_equal({}, agent.settings)
  end

  test 'names are what the daemon CLI can address' do
    %w[captain bot-2 ops_bot].each { assert_predicate build(name: it), :valid?, it }
    ['Captain', '-bot', 'my bot', ''].each { assert_not build(name: it).valid?, it.inspect }
  end

  test 'bot_class must name a bot and homeserver_url be an http URL' do
    assert_predicate build(bot_class: 'EchoBot'), :valid?
    assert_not build(bot_class: 'echo bot').valid?
    assert_not build(bot_class: 'Bots::Missing').valid?
    assert_not build(bot_class: 'String').valid?, 'not a bot'
    assert_not build(homeserver_url: 'matrix.test').valid?
    assert_predicate build(homeserver_url: 'http://localhost:8008'), :valid?
  end

  test 'settings must be an object' do
    assert_not build(settings: [1, 2]).valid?
  end

  test 'daemon-owned columns cannot be written through the model' do
    agent = create_agent

    assert_raises(ActiveRecord::ReadonlyAttributeError) { agent.state = 'online' }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { agent.sync_token = 's1' }
  end

  test 'the database rejects a state the daemon does not use' do
    agent = create_agent

    assert_raises(ActiveRecord::StatementInvalid) { daemon_update(agent, state: 'online_idle') }
  end

  test 'logged_in? and claimed? read what the daemon wrote' do
    agent = daemon_update(create_agent, access_token_ciphertext: 'sealed', claimed_by: 'host-1',
                                        lease_expires_at: 1.minute.from_now, state: 'online')

    assert_predicate agent, :logged_in?
    assert_predicate agent, :claimed?
    assert_predicate agent, :online?
    assert_not daemon_update(agent, lease_expires_at: 1.minute.ago).claimed?
  end

  test 'destroying an agent cascades in the database' do
    agent = create_agent
    insert_room(agent)
    insert_inbox(agent)
    agent.memory[:greeting] = 'hi'

    agent.destroy!

    assert_equal 0, ActiveMatrix::Room.count
    assert_equal 0, ActiveMatrix::InboxEvent.count
    assert_equal 0, ActiveMatrix::Memory.count
  end

  private

  def build(**attributes)
    ActiveMatrix::Agent.new(name: 'bot', bot_class: 'EchoBot', homeserver_url: 'https://matrix.test', **attributes)
  end
end
