# frozen_string_literal: true

require 'test_helper'

class MemoryReaperJobTest < ActiveSupport::TestCase
  setup do
    @agent = create_agent
    ActiveMatrix.config.inbox_retention = 86_400
    ActiveMatrix.config.outbox_retention = 86_400
  end

  test 'reaps expired memories and finished rows past retention, keeps the rest' do
    @agent.memory.write(:stale, 1, expires_in: 1)
    @agent.memory[:kept] = 2
    old_inbox = insert_inbox(@agent, processed_at: 2.days.ago)
    recent_inbox = insert_inbox(@agent, processed_at: 1.hour.ago)
    pending_inbox = insert_inbox(@agent)
    old_sent = outbox(status: 'sent', updated_at: 2.days.ago)
    old_pending = outbox(status: 'pending', updated_at: 2.days.ago)

    travel(5.seconds) { ActiveMatrix::MemoryReaperJob.perform_now }

    assert_equal({ 'kept' => 2 }, @agent.memory.to_h)
    assert_equal [recent_inbox, pending_inbox].map(&:id).sort, ActiveMatrix::InboxEvent.pluck(:id).sort
    assert_not ActiveMatrix::InboxEvent.exists?(old_inbox.id)
    assert_equal [old_pending.id], ActiveMatrix::OutboxCommand.pluck(:id)
    assert_not ActiveMatrix::OutboxCommand.exists?(old_sent.id)
  end

  private

  def outbox(status:, updated_at:)
    ActiveMatrix::OutboxCommand.insert!({ agent_id: @agent.id, kind: 'send', room_id: '!room:matrix.test', status:,
                                          created_at: updated_at, updated_at: })
    ActiveMatrix::OutboxCommand.order(:created_at).last
  end
end
