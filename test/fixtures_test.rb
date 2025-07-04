# frozen_string_literal: true

require 'test_helper'

class FixturesTest < ActiveSupport::TestCase
  # Manually specify fixture paths since we're running in a gem environment
  self.fixture_paths = [File.join(File.dirname(__FILE__), 'dummy', 'test', 'fixtures')]

  # Map fixture names to model classes
  set_fixture_class active_matrix_agents: ActiveMatrix::Agent,
                    active_matrix_agent_stores: ActiveMatrix::AgentStore,
                    active_matrix_chat_sessions: ActiveMatrix::ChatSession,
                    active_matrix_knowledge_bases: ActiveMatrix::KnowledgeBase

  fixtures :active_matrix_agents, :active_matrix_agent_stores, :active_matrix_chat_sessions, :active_matrix_knowledge_bases

  def test_agents_fixtures_load
    agent = active_matrix_agents(:agent_smith)

    assert_equal 'agent_smith', agent.name
    assert_equal 'https://matrix.zion.net', agent.homeserver
    puts "✅ Agent Smith fixture loaded: #{agent.name}"
  end

  def test_agent_stores_fixtures_load
    store = active_matrix_agent_stores(:smith_mission_log)

    assert_equal 'mission_log', store.key
    assert_equal active_matrix_agents(:agent_smith), store.agent
    puts "✅ Agent store fixture loaded: #{store.key}"
  end

  def test_chat_sessions_fixtures_load
    session = active_matrix_chat_sessions(:neo_morpheus_training)

    assert_equal '@morpheus:zion.net', session.user_id
    assert_equal active_matrix_agents(:neo), session.agent
    puts '✅ Chat session fixture loaded'
  end

  def test_knowledge_bases_fixtures_load
    kb = active_matrix_knowledge_bases(:matrix_version)

    assert_equal 'matrix_version', kb.key
    assert_kind_of Hash, kb.value
    puts "✅ Knowledge base fixture loaded: #{kb.key}"
  end
end
