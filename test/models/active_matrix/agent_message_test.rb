# frozen_string_literal: true

require 'test_helper'

class AgentMessageTest < ActiveSupport::TestCase
  test 'a message needs a recipient, a topic and an object payload' do
    to = create_agent

    message = ActiveMatrix::AgentMessage.new(to_agent: to, topic: 'deploy', payload: { 'target' => 'api' })

    assert_predicate message, :valid?
    assert_not ActiveMatrix::AgentMessage.new(to_agent: to, topic: '').valid?
    assert_not ActiveMatrix::AgentMessage.new(to_agent: to, topic: 'deploy', payload: 'api').valid?
    assert_not ActiveMatrix::AgentMessage.new(topic: 'deploy').valid?
  end

  test 'a sender that goes away leaves the message' do
    from = create_agent
    message = ActiveMatrix::AgentMessage.create!(from_agent: from, to_agent: create_agent, topic: 'ping')
    from.destroy!

    assert_nil message.reload.from_agent_id
  end
end
