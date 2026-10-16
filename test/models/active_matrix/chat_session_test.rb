# frozen_string_literal: true

require 'test_helper'

class ChatSessionTest < ActiveSupport::TestCase
  setup { @agent = create_agent }

  test 'for finds the session it created' do
    first = ActiveMatrix::ChatSession.for(agent: @agent, room_id: '!room:matrix.test', user_id: '@alice:matrix.test')
    again = ActiveMatrix::ChatSession.for(agent: @agent, room_id: '!room:matrix.test', user_id: '@alice:matrix.test')

    assert_equal first, again
  end

  test 'record_message! counts and stamps the last message' do
    session = ActiveMatrix::ChatSession.for(agent: @agent, room_id: '!room:matrix.test', user_id: '@alice:matrix.test')
    at = Time.zone.parse('2026-10-16 12:00:00')
    2.times { session.record_message!(at:) }

    assert_equal 2, session.message_count
    assert_equal at, session.last_message_at
  end

  test 'messages are the inbox events from that user in that room' do
    session = ActiveMatrix::ChatSession.for(agent: @agent, room_id: '!room:matrix.test', user_id: '@alice:matrix.test')
    mine = insert_inbox(@agent, sender: '@alice:matrix.test')
    insert_inbox(@agent, sender: '@bob:matrix.test')
    insert_inbox(@agent, sender: '@alice:matrix.test', room_id: '!other:matrix.test')

    assert_equal [mine], session.messages.to_a
  end
end
