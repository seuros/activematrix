# frozen_string_literal: true

# <rails-lens:schema:begin>
# table = "active_matrix_chat_sessions"
# database_dialect = "PostgreSQL"
#
# columns = [
#   { name = "id", type = "integer", pk = true, null = false },
#   { name = "agent_id", type = "integer", null = false },
#   { name = "user_id", type = "string", null = false },
#   { name = "room_id", type = "string", null = false },
#   { name = "context", type = "json" },
#   { name = "message_history", type = "json" },
#   { name = "last_message_at", type = "datetime" },
#   { name = "message_count", type = "integer", null = false, default = "0" },
#   { name = "created_at", type = "datetime", null = false },
#   { name = "updated_at", type = "datetime", null = false }
# ]
#
# indexes = [
#   { name = "index_active_matrix_chat_sessions_on_agent_id", columns = ["agent_id"] },
#   { name = "index_active_matrix_chat_sessions_on_last_message_at", columns = ["last_message_at"] },
#   { name = "index_chat_sessions_on_agent_user_room", columns = ["agent_id", "user_id", "room_id"], unique = true }
# ]
#
# foreign_keys = [
#   { column = "agent_id", references_table = "active_matrix_agents", references_column = "id", name = "fk_rails_53457da357" }
# ]
#
# notes = ["agent:INVERSE_OF", "context:NOT_NULL", "message_history:NOT_NULL", "user_id:LIMIT", "room_id:LIMIT"]
# <rails-lens:schema:end>
module ActiveMatrix
  class ChatSession < ApplicationRecord
    self.table_name = 'active_matrix_chat_sessions'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent'

    validates :user_id, presence: true
    validates :room_id, presence: true
    validates :user_id, uniqueness: { scope: %i[agent_id room_id] }

    # Configuration
    MAX_HISTORY_SIZE = 20

    # Scopes
    scope :recent, -> { order(last_message_at: :desc) }
    scope :active, -> { where('last_message_at > ?', 1.hour.ago) }
    scope :stale, -> { where(last_message_at: ...1.day.ago) }

    # Add a message to the history
    def add_message(message_data)
      messages = message_history['messages'] || []

      # Add new message
      messages << {
        'event_id' => message_data[:event_id],
        'sender' => message_data[:sender],
        'content' => message_data[:content],
        'timestamp' => message_data[:timestamp] || Time.current.to_i
      }

      # Keep only recent messages
      messages = messages.last(MAX_HISTORY_SIZE)

      # Update record
      self.message_history = { 'messages' => messages }
      self.last_message_at = Time.current
      self.message_count = messages.size
      save!

      # Update cache
      write_to_cache
    end

    # Get recent messages
    def recent_messages(limit = 10)
      messages = message_history['messages'] || []
      messages.last(limit)
    end

    # Clear old messages but keep context
    def prune_history!
      messages = message_history['messages'] || []
      self.message_history = { 'messages' => messages.last(5) }
      save!
    end

    # Cache integration
    def cache_key
      "conversation/#{agent_id}/#{user_id}/#{room_id}"
    end

    def write_to_cache
      Rails.cache.write(cache_key, {
                          context: context,
                          recent_messages: recent_messages,
                          last_message_at: last_message_at
                        }, expires_in: 1.hour)
    end

    def self.cleanup_stale!
      stale.destroy_all
    end
  end
end
