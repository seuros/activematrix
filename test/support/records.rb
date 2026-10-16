# frozen_string_literal: true

# Builders for the rows tests need. Daemon-owned tables (rooms, members,
# state, inbox) are written with insert!, the way the daemon writes them:
# their models are read-only from Rails.
module Records
  def create_agent(name: "agent-#{SecureRandom.hex(4)}", **attributes)
    ActiveMatrix::Agent.create!(name:, bot_class: 'EchoBot', homeserver_url: 'https://matrix.test', **attributes)
  end

  # Sets daemon-owned columns, which the model refuses to write.
  def daemon_update(agent, **columns)
    ActiveMatrix::Agent.where(id: agent.id).update_all(columns)
    agent.reload
  end

  def insert_room(agent, room_id: '!room:matrix.test', **attributes)
    ActiveMatrix::Room.insert!({ agent_id: agent.id, room_id:, membership: 'join', **attributes })
    ActiveMatrix::Room.find_by!(agent_id: agent.id, room_id:)
  end

  def insert_state(room, event_type, content, state_key: '', sender: '@alice:matrix.test')
    ActiveMatrix::RoomState.insert!({ agent_id: room.agent_id, room_id: room.room_id, event_type:, state_key:,
                                      sender:, content: })
  end

  def insert_member(room, user_id, membership: 'join')
    ActiveMatrix::RoomMember.insert!({ agent_id: room.agent_id, room_id: room.room_id, user_id:, membership: })
  end

  def insert_inbox(agent, room_id: '!room:matrix.test', sender: '@alice:matrix.test', body: 'hello', **attributes)
    content = { 'msgtype' => 'm.text', 'body' => body }
    ActiveMatrix::InboxEvent.insert!({ agent_id: agent.id, room_id:, sender:, event_id: "$#{SecureRandom.hex(8)}",
                                       event_type: 'm.room.message', content:, raw: { 'content' => content },
                                       **attributes })
    ActiveMatrix::InboxEvent.where(agent_id: agent.id).order(:id).last
  end
end

ActiveSupport.on_load(:active_support_test_case) { include Records }
