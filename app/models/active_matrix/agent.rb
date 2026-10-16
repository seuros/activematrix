# frozen_string_literal: true

module ActiveMatrix
  # A bot account. Rails owns what the agent should be (name, bot class,
  # homeserver, settings, enabled); the daemon owns what it is (state, lease,
  # sync position) and its credentials, which only the daemon can decrypt.
  class Agent < ApplicationRecord
    self.table_name = 'active_matrix_agents'

    # Written by activematrixd. Rails reads them; saving a change through the
    # model is refused rather than racing the daemon.
    DAEMON_COLUMNS = %i[
      state user_id device_id access_token_ciphertext sync_token
      last_error last_error_at heartbeat_at claimed_by lease_expires_at
    ].freeze
    attr_readonly(*DAEMON_COLUMNS)

    enum :state, {
      offline: 'offline', starting: 'starting', online: 'online',
      reconnecting: 'reconnecting', failed: 'failed'
    }

    has_many :rooms, class_name: 'ActiveMatrix::Room', inverse_of: :agent, dependent: nil
    has_many :inbox_events, class_name: 'ActiveMatrix::InboxEvent', inverse_of: :agent, dependent: nil
    has_many :outbox_commands, class_name: 'ActiveMatrix::OutboxCommand', inverse_of: :agent, dependent: nil
    has_many :chat_sessions, class_name: 'ActiveMatrix::ChatSession', inverse_of: :agent, dependent: nil
    has_many :memories, class_name: 'ActiveMatrix::Memory', inverse_of: :agent, dependent: nil
    has_many :received_messages, class_name: 'ActiveMatrix::AgentMessage', foreign_key: :to_agent_id,
                                 inverse_of: :to_agent, dependent: nil

    # The daemon CLI addresses agents by name (`activematrix login captain`).
    validates :name, presence: true, uniqueness: true,
                     format: { with: /\A[a-z0-9][a-z0-9_-]*\z/ }
    validates :bot_class, presence: true, format: { with: /\A(::)?[A-Z]\w*(::[A-Z]\w*)*\z/ }
    validates :homeserver_url, presence: true, format: { with: %r{\Ahttps?://[^\s/]+(/\S*)?\z} }
    validate :settings_is_an_object
    validate :bot_class_is_a_bot

    scope :enabled, -> { where(enabled: true) }

    def logged_in? = access_token_ciphertext.present?

    # Whether a daemon currently holds this agent, by its own heartbeat.
    def claimed? = claimed_by.present? && lease_expires_at.present? && lease_expires_at.future?

    def memory = Memory::Store.new(agent: self)

    private

    def bot_class_is_a_bot
      return if bot_class.blank?

      klass = bot_class.safe_constantize
      return if klass.is_a?(Class) && klass < Bot::Base

      errors.add(:bot_class, 'must be an ActiveMatrix::Bot::Base subclass')
    end

    def settings_is_an_object
      errors.add(:settings, 'must be a JSON object') unless settings.is_a?(Hash)
    end
  end
end
