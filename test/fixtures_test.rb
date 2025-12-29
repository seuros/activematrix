# frozen_string_literal: true

require 'test_helper'

class FixturesTest < ActiveSupport::TestCase
  # Manually specify fixture paths since we're running in a gem environment
  self.fixture_paths = [File.join(File.dirname(__FILE__), 'fixtures')]

  # Map fixture names to model classes
  set_fixture_class agents: ActiveMatrix::Agent,
                    agent_stores: ActiveMatrix::AgentStore,
                    chat_sessions: ActiveMatrix::ChatSession,
                    knowledge_bases: ActiveMatrix::KnowledgeBase

  fixtures :agents, :agent_stores, :chat_sessions, :knowledge_bases

  def test_agents_fixtures_load
    agent = agents(:agent_smith)

    assert_equal 'agent_smith', agent.name
    assert_equal 'https://matrix.zion.net', agent.homeserver
  end

  def test_agent_stores_fixtures_load
    store = agent_stores(:smith_mission_log)

    assert_equal 'mission_log', store.key
    assert_equal agents(:agent_smith), store.agent
  end

  def test_chat_sessions_fixtures_load
    session = chat_sessions(:neo_morpheus_training)

    assert_equal '@morpheus:zion.net', session.user_id
    assert_equal agents(:neo), session.agent
  end

  def test_knowledge_bases_fixtures_load
    kb = knowledge_bases(:matrix_version)

    assert_equal 'matrix_version', kb.key
    assert_kind_of Hash, kb.value
  end
end
