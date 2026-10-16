# frozen_string_literal: true

require 'test_helper'

# Builds a 0.0.x schema in a scratch Postgres schema, seeds it the way 0.0.x
# wrote it, and runs the 0.1 migrations over it.
class UpgradeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  MIGRATIONS = File.expand_path('../../db/migrate', __dir__)
  LAST_0_0_X = 20_251_229_000_000

  setup do
    ActiveRecord::Migration.verbose = false
    @connection = ActiveRecord::Base.connection
    @connection.execute('CREATE SCHEMA upgrade_test')
    @connection.schema_search_path = 'upgrade_test'
    @migrations = ActiveRecord::MigrationContext.new(MIGRATIONS)
    @migrations.up(LAST_0_0_X)
  end

  teardown do
    @connection.schema_search_path = 'public'
    @connection.execute('DROP SCHEMA upgrade_test CASCADE')
  end

  test 'agents keep their identity and intent, and drop unreadable credentials' do
    seed_agent('idle', state: 'online_idle', username: '@idle:matrix.test')
    seed_agent('paused', state: 'paused', username: 'paused')
    seed_agent('broken', state: 'error')

    @migrations.up

    rows = select_rows('SELECT name, state, enabled, user_id FROM active_matrix_agents ORDER BY name')

    assert_equal [['broken', 'failed', true, nil], ['idle', 'online', true, '@idle:matrix.test'],
                  ['paused', 'offline', false, nil]], rows
    assert_not @connection.column_exists?(:active_matrix_agents, :access_token)
    assert_not @connection.column_exists?(:active_matrix_agents, :encrypted_password)
  end

  test 'agent stores, the knowledge base and session context fold into memories' do
    agent_id = seed_agent('captain', state: 'offline')
    insert('active_matrix_agent_stores', agent_id:, key: 'deploys', value: '3')
    insert('active_matrix_knowledge_bases', key: 'motd', value: '"hello"')
    session_id = insert('active_matrix_chat_sessions', agent_id:, user_id: '@alice:matrix.test',
                                                       room_id: '!room:matrix.test', context: '{"topic": "ops"}')

    @migrations.up

    rows = select_rows(<<~SQL.squish)
      SELECT agent_id IS NOT NULL, chat_session_id = '#{session_id}', key, value::text
      FROM active_matrix_memories ORDER BY key
    SQL

    assert_equal [[true, nil, 'deploys', '3'], [false, nil, 'motd', '"hello"'], [true, true, 'topic', '"ops"']], rows
    assert_not @connection.table_exists?(:active_matrix_agent_stores)
    assert_not @connection.table_exists?(:active_matrix_knowledge_bases)
    assert_not @connection.column_exists?(:active_matrix_chat_sessions, :context)
  end

  private

  def seed_agent(name, state:, username: nil)
    insert('active_matrix_agents', name:, state:, username:, bot_class: 'EchoBot',
                                   homeserver: 'https://matrix.test', access_token: 'encrypted-by-0.0.x')
  end

  def insert(table, **values)
    now = @connection.quote(Time.current)
    columns = values.keys.join(', ')
    literals = values.values.map { @connection.quote(it) }.join(', ')
    @connection.select_value(<<~SQL.squish)
      INSERT INTO #{table} (#{columns}, created_at, updated_at) VALUES (#{literals}, #{now}, #{now}) RETURNING id
    SQL
  end

  def select_rows(sql) = @connection.select_rows(sql)
end
