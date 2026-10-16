# frozen_string_literal: true

module ActiveMatrix
  # One user talking to one agent in one room. Conversation memory hangs off
  # it; the message history itself is the inbox.
  class ChatSession < ApplicationRecord
    self.table_name = 'active_matrix_chat_sessions'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent', inverse_of: :chat_sessions
    has_many :memories, class_name: 'ActiveMatrix::Memory', inverse_of: :chat_session, dependent: nil

    validates :user_id, :room_id, presence: true

    scope :recent, -> { order(last_message_at: :desc) }

    # The session for (agent, room, user), created on first contact. Safe
    # against two jobs creating it at once: the unique index decides.
    def self.for(agent:, room_id:, user_id:)
      create_or_find_by!(agent:, room_id:, user_id:)
    end

    # Counts a message atomically, so concurrent handlers do not lose updates.
    def record_message!(at: Time.current)
      self.class.where(id:).update_all(['message_count = message_count + 1, last_message_at = ?', at])
      reload
    end

    def memory = Memory::Store.new(agent:, chat_session: self)

    def messages = agent.inbox_events.where(room_id:, sender: user_id)
  end
end
