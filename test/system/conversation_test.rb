# frozen_string_literal: true

require_relative 'system_helper'

class ConversationTest < SystemTestCase
  setup { boot_bot }

  test 'the bot joins the room it is invited to and answers a command' do
    say '!ping'

    assert_equal ['pong'], wait_for_replies('pong', 1)
  end

  test 'a handler that raises sends nothing, and other rooms carry on' do
    say '!explode'
    failed = eventually('the failed attempt to be recorded') do
      ActiveMatrix::InboxEvent.where(agent_id: @agent.id, room_id: @room, event_type: 'm.room.message')
                              .where('attempts > 0').first
    end

    assert_match(/boom/, failed.last_error)
    assert_nil failed.processed_at

    other = open_room(@alice, @bot)
    say '!ping', room: other

    assert_equal ['pong'], wait_for_replies('pong', 1, room: other)
    assert_empty replies('this reply must never be sent')
    assert_empty ActiveMatrix::OutboxCommand.where(agent_id: @agent.id).where("payload::text LIKE '%must never%'")
  end
end
