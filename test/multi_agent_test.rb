# frozen_string_literal: true

require 'test_helper'

class MultiAgentTest < ActiveSupport::TestCase
  def setup
    ActiveMatrix.configure do |config|
      config.agent_startup_delay = 0
      config.agent_health_check_interval = 1
    end
  end

  def teardown
    ActiveMatrix::AgentRegistry.instance.clear!
  end

  def test_agent_registry
    registry = ActiveMatrix::AgentRegistry.instance

    # Mock agent and bot
    agent = mock_agent('test_bot')
    bot = mock_bot

    # Register agent
    registry.register(agent, bot)

    assert_equal 1, registry.count
    assert registry.running?(agent)

    # Get by ID
    entry = registry.get(agent.id)

    assert_not_nil entry
    assert_equal agent, entry[:record]
    assert_equal bot, entry[:instance]

    # Get by name
    entry = registry.get_by_name('test_bot')

    assert_not_nil entry
    assert_equal agent, entry[:record]

    # Unregister
    registry.unregister(agent)

    assert_equal 0, registry.count
    assert_not registry.running?(agent)
  end

  def test_memory_system
    agent = mock_agent('memory_test')

    # Mock agent_memories association for testing
    active_scope = mock('active_scope')
    active_scope.stubs(:find_by).returns(nil)
    active_scope.stubs(:exists?).returns(false)

    agent_memories = mock('agent_memories')
    agent_memories.stubs(:active).returns(active_scope)
    memory_mock = mock('memory')
    memory_mock.stubs(:save!).returns(true)
    memory_mock.stubs(:value).returns(nil)
    agent_memories.stubs(:find_or_initialize_by).returns(memory_mock)

    agent.stubs(:agent_memories).returns(agent_memories)

    # Agent memory - test interface
    agent_memory = ActiveMatrix::Memory::AgentMemory.new(agent)

    # These would work with a real database
    assert_respond_to agent_memory, :set
    assert_respond_to agent_memory, :get
    assert_respond_to agent_memory, :increment
    assert_respond_to agent_memory, :remember
  end

  def test_conversation_memory
    agent = mock_agent('conv_test')
    user_id = '@user:example.com'
    room_id = '!room:example.com'

    conv_memory = ActiveMatrix::Memory::ConversationMemory.new(agent, user_id, room_id)

    # Test that the interface exists
    assert_respond_to conv_memory, :context
    assert_respond_to conv_memory, :update_context
    assert_respond_to conv_memory, :add_message
    assert_respond_to conv_memory, :recent_messages
    assert_respond_to conv_memory, :[]
    assert_respond_to conv_memory, :[]=
  end

  def test_global_memory
    global = ActiveMatrix::Memory::GlobalMemory.instance

    # Since we don't have ActiveRecord in tests, test the interface
    # In a real Rails app, this would work with the database
    if defined?(::GlobalMemory)
      # Set and get
      global.set('global_key', 'global_value')

      assert_equal 'global_value', global.get('global_key')

      # Test categories
      global.set('cat_key1', 'value1', category: 'test_cat')
      global.set('cat_key2', 'value2', category: 'test_cat')

      values = global.by_category('test_cat')

      assert_equal 2, values.size
      assert_equal 'value1', values['cat_key1']
      assert_equal 'value2', values['cat_key2']
    else
      # Just test that the methods exist
      assert_respond_to global, :get
      assert_respond_to global, :set
      assert_respond_to global, :exists?
      assert_respond_to global, :delete
      assert_respond_to global, :by_category
    end
  end

  def test_bot_multi_instance_base
    # Test with agent that has a client
    agent = mock_agent('multi_bot')

    # Create a real ActiveMatrix::Client instance with mocked methods
    client = ActiveMatrix::Client.allocate # Create without calling initialize
    client.stubs(:on_event).returns(mock('event_handler', add_handler: true))
    client.stubs(:on_invite_event).returns(mock('invite_handler', add_handler: true))
    client.stubs(:homeserver).returns('https://example.com')

    agent.stubs(:client).returns(client)

    # Initialize with agent record
    bot = ActiveMatrix::Bot::MultiInstanceBase.new(agent)

    assert_equal agent, bot.agent_record
    assert_equal 'multi_bot', bot.agent_name

    # Test memory access
    assert_kind_of ActiveMatrix::Memory::AgentMemory, bot.memory
    assert_kind_of ActiveMatrix::Memory::GlobalMemory, bot.global_memory
  end

  def test_configuration
    config = ActiveMatrix::Configuration.new

    assert_equal 2, config.agent_startup_delay
    assert_equal 10, config.max_agents_per_process
    assert_equal 30, config.agent_health_check_interval

    # Test configure block
    ActiveMatrix.configure do |c|
      c.agent_startup_delay = 5
    end

    assert_equal 5, ActiveMatrix.config.agent_startup_delay
  end

  private

  def mock_agent(name)
    agent = mock('agent')
    agent.stubs(:id).returns(1)
    agent.stubs(:name).returns(name)
    agent.stubs(:state).returns('online')
    agent.stubs(:homeserver).returns('https://example.com')
    agent.stubs(:bot_class).returns('TestBot')
    agent.stubs(:last_active_at).returns(Time.zone.now)
    agent.stubs(:settings).returns({}) # Agent settings for configuration
    agent
  end

  def mock_bot
    bot = mock('bot')
    bot.stubs(:agent_name).returns('test_bot')
    bot
  end
end
