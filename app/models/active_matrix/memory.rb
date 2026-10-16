# frozen_string_literal: true

module ActiveMatrix
  # One remembered value. Which tier it belongs to follows from its owners:
  #   global        no agent, no chat session
  #   agent         agent only
  #   conversation  chat session (and its agent)
  #
  # Use it through Memory::Store (Agent#memory, ChatSession#memory,
  # Memory.global) rather than directly.
  class Memory < ApplicationRecord
    self.table_name = 'active_matrix_memories'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent', optional: true, inverse_of: :memories
    belongs_to :chat_session, class_name: 'ActiveMatrix::ChatSession', optional: true, inverse_of: :memories

    validates :key, presence: true

    scope :live, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }
    scope :expired, -> { where(expires_at: ...Time.current) }

    def self.global = Store.new
  end
end
