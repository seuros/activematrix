# frozen_string_literal: true

module ActiveMatrix
  # Helpers for testing bots without a daemon or a homeserver: an event goes
  # into the inbox the way activematrixd writes it, the drain job runs the
  # bot right away, and assertions read what the bot put in the outbox.
  #
  #   class EchoBotTest < ActiveSupport::TestCase
  #     include ActiveMatrix::Testing
  #
  #     test 'answers ping' do
  #       agent = ActiveMatrix::Agent.create!(name: 'echo', bot_class: 'EchoBot', homeserver_url: 'https://matrix.test')
  #       deliver_message(agent, '!ping')
  #       assert_replied agent, 'pong'
  #     end
  #   end
  module Testing
    DEFAULT_ROOM = '!room:matrix.test'
    DEFAULT_SENDER = '@alice:matrix.test'

    # A text message from `sender` in `room_id`, handled at once.
    def deliver_message(agent, body, sender: DEFAULT_SENDER, room_id: DEFAULT_ROOM, content: {})
      deliver_event(agent, event_type: 'm.room.message', sender:, room_id:,
                           content: { 'msgtype' => 'm.text', 'body' => body }.merge(content))
    end

    # Any timeline event, handled at once. Returns the inbox event.
    def deliver_event(agent, event_type:, content:, sender: DEFAULT_SENDER, room_id: DEFAULT_ROOM, state_key: nil,
                      kind: 'timeline')
      event_id = "$test#{SecureRandom.hex(8)}"
      raw = { 'type' => event_type, 'event_id' => event_id, 'sender' => sender, 'content' => content,
              'state_key' => state_key }.compact
      InboxEvent.insert!({ agent_id: agent.id, room_id:, event_id:, kind:, event_type:, sender:, state_key:,
                           content:, raw: })
      DrainRoomJob.perform_now(agent.id, room_id)
      InboxEvent.find_by!(agent_id: agent.id, event_id:)
    end

    def deliver_invite(agent, room_id: DEFAULT_ROOM, sender: DEFAULT_SENDER)
      deliver_event(agent, event_type: 'm.room.member', kind: 'invite', sender:, room_id:, state_key: agent.user_id,
                           content: { 'membership' => 'invite' })
    end

    # The bodies of the text messages the agent sent, oldest first.
    def replies(agent, room_id: nil)
      scope = agent.outbox_commands.where(kind: 'send').order(:created_at, :id)
      scope = scope.where(room_id:) if room_id
      scope.filter_map { it.payload.dig('content', 'body') if it.payload['event_type'] == 'm.room.message' }
    end

    def assert_replied(agent, body, room_id: nil)
      sent = replies(agent, room_id:)

      assert_includes sent, body, "expected #{agent.name} to reply #{body.inspect}; it sent #{sent.inspect}"
    end

    def assert_no_replies(agent)
      assert_empty replies(agent), "expected #{agent.name} to stay quiet"
    end

    # The last outbox command of `kind`, after asserting there is one.
    def assert_outbox(agent, kind)
      command = agent.outbox_commands.where(kind: kind.to_s).order(:created_at, :id).last

      assert command, "expected #{agent.name} to queue a #{kind} command"
      command
    end
  end
end
