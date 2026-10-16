# frozen_string_literal: true

require_relative 'system_helper'

class LifecycleTest < SystemTestCase
  setup { boot_bot }

  test 'TERM drains within the timeout, and a restart resumes without replaying' do
    say '!ping'
    wait_for_replies('pong', 1)

    status, seconds = @daemon.stop

    assert_predicate status, :success?, "activematrixd exited with #{status}"
    assert_operator seconds, :<, SHUTDOWN_TIMEOUT
    @agent.reload

    assert_predicate @agent, :offline?
    assert_nil @agent.claimed_by

    @daemon = start_daemon
    wait_online(@agent)
    say '!ping'

    assert_equal %w[pong pong], wait_for_replies('pong', 2)
    consistently('the first ping not to be answered again', seconds: 1) { replies('pong').size == 2 }
  end

  test 'a disabled agent stops, and answers what it missed once enabled again' do
    @agent.update!(enabled: false)
    eventually('the lease to be released') { @agent.reload.offline? && @agent.claimed_by.nil? }

    say '!ping'
    consistently('no answer while disabled', seconds: 2) { replies('pong').empty? }

    @agent.update!(enabled: true)

    assert_equal ['pong'], wait_for_replies('pong', 1)
  end

  # Another daemon took the agent over (this one missed its heartbeats): this
  # one must stop at once and write nothing more for it.
  test 'a lost lease halts the agent and leaves its row to the new owner' do
    ActiveMatrix::Agent.where(id: @agent.id).update_all(claimed_by: 'another-node', lease_expires_at: 1.hour.from_now)

    say '!ping'
    consistently('no answer without the lease', seconds: 3) { replies('pong').empty? }
    @agent.reload

    assert_equal 'another-node', @agent.claimed_by
    assert_predicate @agent, :online?, 'the old owner must not record a state for it'
    assert_empty @agent.inbox_events.where(event_type: 'm.room.message')
  end
end
