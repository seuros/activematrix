# frozen_string_literal: true

module ActiveMatrix
  # A message from one agent (or the app) to another agent. Delivered through
  # ActiveJob; kept for audit and so a crashed job can be retried.
  class AgentMessage < ApplicationRecord
    self.table_name = 'active_matrix_agent_messages'

    belongs_to :from_agent, class_name: 'ActiveMatrix::Agent', optional: true
    belongs_to :to_agent, class_name: 'ActiveMatrix::Agent', inverse_of: :received_messages

    validates :topic, presence: true
    validate :payload_is_an_object

    scope :pending, -> { where(processed_at: nil) }

    private

    def payload_is_an_object
      errors.add(:payload, 'must be a JSON object') unless payload.is_a?(Hash)
    end
  end
end
