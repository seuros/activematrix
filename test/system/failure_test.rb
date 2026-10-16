# frozen_string_literal: true

require_relative 'system_helper'

class FailureTest < SystemTestCase
  setup { boot_bot }

  test 'a rejected token fails its agent and leaves the others running' do
    other_bot = @homeserver.register(unique('other'))
    other = agent_for(other_bot)
    wait_online(other)
    other_room = open_room(@alice, other_bot)

    @homeserver.revoke(@bot)
    say '!ping' # wakes the bot's long-poll; its next request is refused
    eventually('the agent to fail') { @agent.reload.failed? }

    assert_match(/rejected the access token/, @agent.last_error)
    assert_nil @agent.claimed_by

    say '!ping', room: other_room, to: other_bot

    assert_equal ['pong'], wait_for_replies('pong', 1, room: other_room, sender: other_bot)
  end

  test 'a 429 storm on send is absorbed: one reply, under one transaction id' do
    fake_only!
    3.times do
      @homeserver.fault(method: 'PUT', path_prefix: '/_matrix/client/v3/rooms/', status: 429,
                        errcode: 'M_LIMIT_EXCEEDED', retry_after_ms: 100)
    end

    say '!ping'

    assert_equal ['pong'], wait_for_replies('pong', 1)
    sends = @homeserver.requests.select { it['method'] == 'PUT' && it['path'].include?('/send/m.room.message/') }

    assert_equal 4, sends.size, 'three refused attempts and the one that went through'
    assert_equal 1, sends.map { it['path'] }.uniq.size, 'every attempt reuses the transaction id'
    consistently('a single pong', seconds: 1) { replies('pong').size == 1 }
  end
end
