# frozen_string_literal: true

require 'test_helper'

class DrainRoomJobTest < ActiveSupport::TestCase
  include ActiveMatrix::Testing

  setup { @agent = create_agent }

  test 'pending events are handled in the order they were ingested' do
    insert_inbox(@agent, body: '!remember a 1')
    insert_inbox(@agent, body: '!count')
    insert_inbox(@agent, body: '!ping', room_id: '!other:matrix.test')

    ActiveMatrix::DrainRoomJob.perform_now(@agent.id, '!room:matrix.test')

    assert_equal ['Remembered a', 'Count: 1'], replies(@agent)
    assert_equal 1, ActiveMatrix::InboxEvent.pending.count, 'other rooms wait for their own job'
  end

  test 'handled events are not handled again' do
    insert_inbox(@agent, body: '!count')
    2.times { ActiveMatrix::DrainRoomJob.perform_now(@agent.id, '!room:matrix.test') }

    assert_equal ['Count: 1'], replies(@agent)
  end

  test 'an event that keeps failing is set aside so the room moves on' do
    stuck = insert_inbox(@agent, body: '!explode', attempts: ActiveMatrix::DrainRoomJob::MAX_ATTEMPTS - 1)
    insert_inbox(@agent, body: '!ping')

    ActiveMatrix::DrainRoomJob.perform_now(@agent.id, '!room:matrix.test')

    assert_predicate stuck.reload, :processed?
    assert_match(/boom/, stuck.last_error)
    assert_equal ['pong'], replies(@agent)
  end

  test 'an agent whose bot class is gone fails its events instead of dropping them' do
    ActiveMatrix::Agent.where(id: @agent.id).update_all(bot_class: 'GoneBot')
    event = insert_inbox(@agent, body: '!ping')

    ActiveMatrix::DrainRoomJob.perform_now(@agent.id, '!room:matrix.test')

    assert_match(/GoneBot/, event.reload.last_error)
    assert_not event.processed?
  end

  test 'a deleted agent is a no-op' do
    assert_nothing_raised { ActiveMatrix::DrainRoomJob.perform_now(SecureRandom.uuid, '!room:matrix.test') }
  end
end
