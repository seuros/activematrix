# frozen_string_literal: true

require 'test_helper'

class OutboxCommandTest < ActiveSupport::TestCase
  setup { @agent = create_agent }

  test 'a command needs a known kind and, for most kinds, a room' do
    assert_not build(kind: 'teleport').valid?
    assert_not build(kind: 'send', room_id: nil).valid?
    assert_predicate build(kind: 'create_room', room_id: nil), :valid?
    assert_not build(payload: %w[not an object]).valid?
  end

  test 'new commands are pending; what the daemon reports is read-only' do
    command = build.tap(&:save!)

    assert_predicate command, :pending?
    assert_not command.finished?
    assert_raises(ActiveRecord::ReadonlyAttributeError) { command.result = { 'event_id' => '$x' } }
  end

  test 'wait refuses to run inside a transaction' do
    command = build.tap(&:save!)

    assert_raises(ActiveMatrix::OutboxCommand::WaitInTransaction) { command.wait(timeout: 0.1) }
  end

  private

  def build(**attributes)
    ActiveMatrix::OutboxCommand.new(agent: @agent, kind: 'send', room_id: '!room:matrix.test',
                                    payload: { 'msgtype' => 'm.text', 'body' => 'hi' }, **attributes)
  end
end

# Commit-time behaviour needs real commits.
class OutboxCommandNotifyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @agent = create_agent
    @listener = ActiveRecord::Base.connection_pool.checkout
    @listener.raw_connection.exec("LISTEN #{ActiveMatrix::OutboxCommand::NOTIFY_CHANNEL}")
  end

  teardown do
    ActiveRecord::Base.connection_pool.checkin(@listener)
    @agent.destroy!
  end

  test 'the daemon is woken when the creating transaction commits, not before' do
    command = nil
    ActiveRecord::Base.transaction do
      command = create_command

      assert_nil next_notification(0.1), 'notified before commit'
    end

    assert_equal command.id, next_notification(2)
  end

  test 'a rolled-back command never wakes the daemon' do
    ActiveRecord::Base.transaction do
      create_command
      raise ActiveRecord::Rollback
    end

    assert_nil next_notification(0.2)
    assert_equal 0, ActiveMatrix::OutboxCommand.count
  end

  test 'wait returns once the daemon reports the command finished' do
    command = create_command
    daemon = Thread.new do
      sleep 0.2
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute(<<~SQL.squish)
          UPDATE active_matrix_outbox SET status = 'sent', result = '{"event_id": "$sent"}', sent_at = now()
          WHERE id = #{connection.quote(command.id)}
        SQL
        connection.execute("NOTIFY #{ActiveMatrix::OutboxCommand::DONE_CHANNEL}, #{connection.quote(command.id)}")
      end
    end

    assert_predicate command.wait(timeout: 5), :sent?
    assert_equal '$sent', command.result['event_id']
  ensure
    daemon&.join
  end

  test 'wait gives up after its timeout' do
    command = create_command

    assert_raises(ActiveMatrix::OutboxCommand::Timeout) { command.wait(timeout: 0.2) }
  end

  private

  def create_command
    ActiveMatrix::OutboxCommand.create!(agent: @agent, kind: 'send', room_id: '!room:matrix.test',
                                        payload: { 'body' => 'hi' })
  end

  def next_notification(timeout)
    payload = nil
    @listener.raw_connection.wait_for_notify(timeout) { |_channel, _pid, data| payload = data }
    payload
  end
end
