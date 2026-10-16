# frozen_string_literal: true

require 'test_helper'

class InboxEventTest < ActiveSupport::TestCase
  setup { @agent = create_agent }

  test 'pending events come back in ingest order' do
    first = insert_inbox(@agent, body: 'one')
    second = insert_inbox(@agent, body: 'two')
    insert_inbox(@agent, body: 'done', processed_at: Time.current)

    assert_equal [first, second], ActiveMatrix::InboxEvent.pending.in_order.to_a
    assert_equal 'one', first.body
    assert_predicate first, :message?
  end

  test 'an event id is ingested once per agent' do
    event = insert_inbox(@agent)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveMatrix::InboxEvent.insert!({ agent_id: @agent.id, room_id: event.room_id, event_id: event.event_id,
                                         event_type: 'm.room.message', sender: event.sender })
    end
  end

  test 'what the daemon ingested cannot be rewritten' do
    event = insert_inbox(@agent)

    assert_raises(ActiveRecord::ReadonlyAttributeError) { event.content = {} }
    event.update!(processed_at: Time.current, attempts: 1)

    assert_predicate event.reload, :processed?
  end
end
