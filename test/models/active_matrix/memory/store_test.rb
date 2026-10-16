# frozen_string_literal: true

require 'test_helper'

class MemoryStoreTest < ActiveSupport::TestCase
  setup do
    @agent = create_agent
    @session = ActiveMatrix::ChatSession.for(agent: @agent, room_id: '!room:matrix.test', user_id: '@alice:matrix.test')
  end

  test 'the three tiers keep the same key apart' do
    ActiveMatrix::Memory.global[:topic] = 'global'
    @agent.memory[:topic] = 'agent'
    @session.memory[:topic] = 'conversation'

    assert_equal 'global', ActiveMatrix::Memory.global[:topic]
    assert_equal 'agent', @agent.memory[:topic]
    assert_equal 'conversation', @session.memory[:topic]
    assert_equal 3, ActiveMatrix::Memory.count
  end

  test 'values are any JSON and writes replace' do
    store = @agent.memory
    store[:config] = { 'retries' => 3 }
    store[:config] = { 'retries' => 5 }
    store[:names] = %w[a b]

    assert_equal({ 'retries' => 5 }, store[:config])
    assert_equal %w[a b], store['names']
    assert_equal({ 'config' => { 'retries' => 5 }, 'names' => %w[a b] }, store.to_h)
  end

  test 'fetch falls back to a default or a block' do
    assert_equal 'none', @agent.memory.fetch(:missing, 'none')
    assert_equal 'computed missing', @agent.memory.fetch(:missing) { "computed #{it}" }
    assert_not @agent.memory.key?(:missing)
  end

  test 'expired values read as missing, and writing starts them afresh' do
    store = @agent.memory
    store.write(:token, 'short-lived', expires_in: 60)

    travel 2.minutes do
      assert_nil store[:token]
      assert_not store.key?(:token)
      store[:token] = 'renewed'

      assert_equal 'renewed', store[:token]
    end
  end

  test 'delete returns the removed value' do
    @agent.memory[:greeting] = 'hi'

    assert_equal 'hi', @agent.memory.delete(:greeting)
    assert_nil @agent.memory.delete(:greeting)
  end

  test 'increment counts from zero and restarts after expiry' do
    store = @session.memory

    assert_equal 1, store.increment(:messages)
    assert_equal 6, store.increment(:messages, by: 5)
    store.write(:window, 10, expires_in: 1)

    travel 5.seconds do
      assert_equal 1, store.increment(:window)
    end
  end

  test 'incrementing a value that is not a number raises' do
    @agent.memory[:name] = 'captain'

    assert_raises(ActiveRecord::StatementInvalid) { @agent.memory.increment(:name) }
  end
end

# Concurrent increments need connections of their own, so real commits.
class MemoryStoreConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown { ActiveMatrix::Memory.global.delete(:hits) }

  test 'concurrent increments never lose an update' do
    threads = Array.new(5) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { 20.times { ActiveMatrix::Memory.global.increment(:hits) } }
      end
    end
    threads.each(&:join)

    assert_equal 100, ActiveMatrix::Memory.global[:hits]
  end
end
