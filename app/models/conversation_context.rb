# frozen_string_literal: true

class ConversationContext < ApplicationRecord
  belongs_to :matrix_agent

  validates :user_id, presence: true
  validates :room_id, presence: true
  validates :user_id, uniqueness: { scope: %i[matrix_agent_id room_id] }

  # Configuration
  MAX_HISTORY_SIZE = 20

  # Scopes
  scope :recent, -> { order(last_message_at: :desc) }
  scope :active, -> { where('last_message_at > ?', 1.hour.ago) }
  scope :stale, -> { where('last_message_at < ?', 1.day.ago) }

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
    "conversation/#{matrix_agent_id}/#{user_id}/#{room_id}"
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
