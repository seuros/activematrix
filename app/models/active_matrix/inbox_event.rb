# frozen_string_literal: true

module ActiveMatrix
  # An event the daemon ingested from /sync. Ids increase in the order the
  # daemon saw events, which is the order handlers run in. Rails handles each
  # one exactly once: processed_at is stamped in the handler's transaction.
  class InboxEvent < ApplicationRecord
    self.table_name = 'active_matrix_inbox'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent', inverse_of: :inbox_events

    attr_readonly :agent_id, :room_id, :event_id, :kind, :event_type, :sender, :state_key,
                  :content, :raw, :origin_server_ts

    scope :pending, -> { where(processed_at: nil) }
    scope :processed, -> { where.not(processed_at: nil) }
    scope :in_order, -> { order(:id) }

    def processed? = processed_at.present?

    def invite? = kind == 'invite'

    def message? = event_type == 'm.room.message'

    def body = content['body']
  end
end
