# frozen_string_literal: true

module ActiveMatrix
  module Bot
    # What a handler can do. Every action writes an outbox command in the
    # handler's transaction; the daemon sends it once the transaction
    # commits, and never if it rolls back.
    module Actions
      # Sends text to the room. `thread: true` answers in the event's thread
      # (starting one on it if needed); `quote: true` replies to it.
      def reply(text, html: nil, notice: false, thread: false, quote: false, mentions: [])
        message = notice ? Content.notice(text, html:, mentions:) : Content.text(text, html:, mentions:)
        message = Content.thread(thread_root, message, in_reply_to: event.event_id) if thread
        message = Content.reply(event.event_id, message) if quote && !thread
        send_event('m.room.message', message)
      end

      def send_event(event_type, content, room_id: self.room_id)
        outbox('send', room_id:, payload: { 'event_type' => event_type, 'content' => content })
      end

      def react(key, to: event.event_id)
        send_event('m.reaction', Content.reaction(to, key))
      end

      def edit(event_id, text, html: nil)
        send_event('m.room.message', Content.edit(event_id, Content.text(text, html:)))
      end

      def redact(event_id = event.event_id, reason: nil)
        outbox('redact', payload: { 'event_id' => event_id, 'reason' => reason }.compact)
      end

      def set_state(event_type, content, state_key: '')
        outbox('state', payload: { 'event_type' => event_type, 'state_key' => state_key, 'content' => content })
      end

      # `typing(on: false)` stops it early.
      def typing(on: true, timeout: 30)
        outbox('typing', payload: { 'typing' => on, 'timeout_ms' => timeout * 1000 })
      end

      def read_receipt(event_id = event.event_id)
        outbox('receipt', payload: { 'event_id' => event_id })
      end

      # Joins `room`: a room id or an alias, by default the event's room
      # (which is how an invite is accepted).
      def join(room = room_id)
        return outbox('join', room_id: room) if room.to_s.start_with?('!')

        outbox('join', room_id: nil, payload: { 'room' => room })
      end

      def leave(room = room_id) = outbox('leave', room_id: room)

      def invite(user_id, room: room_id) = outbox('invite', room_id: room, payload: { 'user_id' => user_id })

      def kick(user_id, reason: nil, room: room_id) = membership('kick', user_id, reason, room)
      def ban(user_id, reason: nil, room: room_id) = membership('ban', user_id, reason, room)
      def unban(user_id, room: room_id) = membership('unban', user_id, nil, room)

      # Hands work to another agent. Its bot gets `payload` in the
      # `on_agent_message(topic)` handler, in a job of its own, enqueued once
      # this handler's transaction commits.
      def deliver_to(agent_name, topic, payload = {})
        recipient = Agent.find_by!(name: agent_name.to_s)
        message = AgentMessage.create!(from_agent: agent, to_agent: recipient, topic: topic.to_s, payload:)
        AgentMessageJob.perform_later(message.id)
        message
      end

      private

      def membership(kind, user_id, reason, room)
        outbox(kind, room_id: room, payload: { 'user_id' => user_id, 'reason' => reason }.compact)
      end

      def outbox(kind, room_id: self.room_id, payload: {})
        OutboxCommand.create!(agent:, kind:, room_id:, payload:)
      end

      # The thread the event is in, or the event itself to start one.
      def thread_root
        relates = content['m.relates_to'] || {}
        relates['rel_type'] == 'm.thread' ? relates['event_id'] : event.event_id
      end
    end
  end
end
