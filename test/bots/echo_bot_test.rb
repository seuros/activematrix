# frozen_string_literal: true

require 'test_helper'

# The bot DSL, through the dummy app's EchoBot and ActiveMatrix::Testing.
class EchoBotTest < ActiveSupport::TestCase
  include ActiveMatrix::Testing
  include ActiveJob::TestHelper

  setup do
    @agent = create_agent(user_id: '@echo:matrix.test')
    daemon_update(@agent, user_id: '@echo:matrix.test')
    @room = insert_room(@agent)
  end

  test 'commands reply, and replies mention nobody by accident' do
    deliver_message(@agent, '!ping')

    assert_replied @agent, 'pong'
    assert_equal({ 'user_ids' => [] }, assert_outbox(@agent, :send).payload.dig('content', 'm.mentions'))
  end

  test 'raw commands get the text as typed, and settings are typed' do
    @agent.update!(settings: { 'shout' => 'true' })

    deliver_message(@agent, '!echo  hello   world')

    assert_replied @agent, 'HELLO   WORLD'
  end

  test 'arguments map onto the block, flags onto its keywords' do
    insert_state(@room, 'm.room.power_levels', { 'users' => { '@alice:matrix.test' => 50 } })

    deliver_message(@agent, '!deploy api')
    deliver_message(@agent, '!deploy api us --force')

    assert_equal ['Deploying api to eu', 'Deploying api to us (forced)'], replies(@agent)
  end

  test 'wrong arguments or unknown flags answer with the usage' do
    insert_state(@room, 'm.room.power_levels', { 'users' => { '@alice:matrix.test' => 50 } })

    deliver_message(@agent, '!deploy')
    deliver_message(@agent, '!deploy api --forse')

    assert_equal ['Usage: !deploy TARGET [REGION] [--force]'] * 2, replies(@agent)
  end

  test 'power guards read the mirrored power levels' do
    deliver_message(@agent, '!deploy api')

    assert_equal ['!deploy needs power level 50.'], replies(@agent)
  end

  test 'thread replies answer in the thread of the event' do
    insert_state(@room, 'm.room.power_levels', { 'users_default' => 100 })

    event = deliver_message(@agent, '!deploy api')

    relates = assert_outbox(@agent, :send).payload.dig('content', 'm.relates_to')

    assert_equal({ 'rel_type' => 'm.thread', 'event_id' => event.event_id, 'is_falling_back' => true,
                   'm.in_reply_to' => { 'event_id' => event.event_id } }, relates)
  end

  test 'memory, conversation memory and counters persist across events' do
    deliver_message(@agent, '!remember color blue')
    2.times { deliver_message(@agent, '!count') }

    assert_equal 'blue', @agent.memory['color']
    session = ActiveMatrix::ChatSession.for(agent: @agent, room_id: @room.room_id, user_id: '@alice:matrix.test')

    assert_equal 'color', session.memory[:last_key]
    assert_equal ['Remembered color', 'Count: 1', 'Count: 2'], replies(@agent)
  end

  test 'rescue_from answers handled errors and the event counts as handled' do
    event = deliver_message(@agent, '!fail')

    assert_replied @agent, 'Sorry: that went wrong'
    assert_predicate event.reload, :processed?
  end

  test 'an unhandled error rolls back the reply and leaves the event to retry' do
    event = deliver_message(@agent, '!explode')

    assert_no_replies @agent
    event.reload

    assert_not event.processed?
    assert_equal 1, event.attempts
    assert_match(/boom/, event.last_error)
    assert_enqueued_jobs 1, only: ActiveMatrix::DrainRoomJob
  end

  test 'before_command callbacks can halt the command' do
    deliver_message(@agent, '!secret', sender: '@mallory:matrix.test')
    deliver_message(@agent, '!secret')

    assert_equal ['Not you.', 'the secret'], replies(@agent)
  end

  test 'help lists the commands' do
    deliver_message(@agent, '!help')

    assert_match(/!ping  Answer pong/, replies(@agent).first)
  end

  test 'event handlers take guards, and the bot ignores its own joins' do
    deliver_event(@agent, event_type: 'm.room.member', state_key: '@bob:matrix.test', sender: '@bob:matrix.test',
                          content: { 'membership' => 'join' })
    deliver_event(@agent, event_type: 'm.room.member', state_key: '@echo:matrix.test', sender: '@echo:matrix.test',
                          content: { 'membership' => 'join' })

    assert_equal ['Welcome, @bob:matrix.test!'], replies(@agent)
  end

  test 'reactions and invites reach their handlers' do
    deliver_event(@agent, event_type: 'm.reaction',
                          content: { 'm.relates_to' => { 'event_id' => '$x', 'key' => '👍' } })
    deliver_invite(@agent, room_id: '!new:matrix.test')

    reaction = @agent.outbox_commands.find_by(kind: 'send').payload

    assert_equal 'm.reaction', reaction['event_type']
    assert_equal({ 'rel_type' => 'm.annotation', 'event_id' => '$x', 'key' => '👀' },
                 reaction.dig('content', 'm.relates_to'))
    assert_equal '!new:matrix.test', assert_outbox(@agent, :join).room_id
  end

  test 'notices, edits and plain text are not commands' do
    deliver_message(@agent, '!ping', content: { 'msgtype' => 'm.notice' })
    deliver_message(@agent, '!ping', content: { 'm.relates_to' => { 'rel_type' => 'm.replace', 'event_id' => '$x' } })
    deliver_message(@agent, 'ping')

    assert_no_replies @agent
  end

  test 'agents hand work to each other once the handler commits' do
    worker = create_agent(name: 'worker')

    deliver_message(@agent, '!handoff worker')

    message = ActiveMatrix::AgentMessage.sole

    assert_equal [@agent, worker, 'work'], [message.from_agent, message.to_agent, message.topic]
    perform_enqueued_jobs(only: ActiveMatrix::AgentMessageJob)

    assert_equal '@alice:matrix.test', worker.memory[:work_from]
    assert_predicate message.reload.processed_at, :present?
  end
end
