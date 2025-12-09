# frozen_string_literal: true

require 'bcrypt'

# <rails-lens:schema:begin>
# table = "active_matrix_agents"
# database_dialect = "PostgreSQL"
#
# columns = [
#   { name = "id", type = "integer", pk = true, null = false },
#   { name = "name", type = "string", null = false },
#   { name = "homeserver", type = "string", null = false },
#   { name = "username", type = "string", null = false },
#   { name = "bot_class", type = "string", null = false },
#   { name = "state", type = "string", null = false, default = "offline" },
#   { name = "access_token", type = "string" },
#   { name = "encrypted_password", type = "string" },
#   { name = "settings", type = "json" },
#   { name = "last_sync_token", type = "string" },
#   { name = "last_active_at", type = "datetime" },
#   { name = "messages_handled", type = "integer", null = false, default = "0" },
#   { name = "created_at", type = "datetime", null = false },
#   { name = "updated_at", type = "datetime", null = false }
# ]
#
# indexes = [
#   { name = "index_active_matrix_agents_on_homeserver", columns = ["homeserver"] },
#   { name = "index_active_matrix_agents_on_name", columns = ["name"], unique = true },
#   { name = "index_active_matrix_agents_on_state", columns = ["state"] }
# ]
#
# [callbacks]
# before_save = [{ method = "encrypt_password", if = ["password_changed?"] }]
# around_validation = [{ method = "machine" }]
#
# notes = ["agent_stores:INVERSE_OF", "chat_sessions:INVERSE_OF", "agent_stores:N_PLUS_ONE", "chat_sessions:N_PLUS_ONE", "access_token:NOT_NULL", "encrypted_password:NOT_NULL", "settings:NOT_NULL", "name:LIMIT", "homeserver:LIMIT", "username:LIMIT", "bot_class:LIMIT", "state:LIMIT", "access_token:LIMIT", "encrypted_password:LIMIT", "last_sync_token:LIMIT", "username:INDEX", "access_token:INDEX", "last_sync_token:INDEX"]
# <rails-lens:schema:end>
module ActiveMatrix
  class Agent < ApplicationRecord
    self.table_name = 'active_matrix_agents'

    # Associations
    has_many :agent_stores, class_name: 'ActiveMatrix::AgentStore', dependent: :destroy
    has_many :chat_sessions, class_name: 'ActiveMatrix::ChatSession', dependent: :destroy

    # Validations
    validates :name, presence: true, uniqueness: true
    validates :homeserver, presence: true
    validates :username, presence: true
    validates :bot_class, presence: true
    validate :valid_bot_class?

    # Scopes
    scope :active, -> { where.not(state: %i[offline error]) }
    scope :online, -> { where(state: %i[online_idle online_busy]) }
    scope :offline, -> { where(state: :offline) }

    # Encrypts password before saving
    before_save :encrypt_password, if: :password_changed?

    # State machine for agent lifecycle
    state_machine :state, initial: :offline do
      state :offline
      state :connecting
      state :online_idle
      state :online_busy
      state :error
      state :paused

      event :connect do
        transition %i[offline error paused] => :connecting
      end

      event :connection_established do
        transition connecting: :online_idle
      end

      after_transition to: :online_idle do |agent|
        agent.update(last_active_at: Time.current)
      end

      event :start_processing do
        transition online_idle: :online_busy
      end

      event :finish_processing do
        transition online_busy: :online_idle
      end

      event :disconnect do
        transition %i[connecting online_idle online_busy] => :offline
      end

      event :encounter_error do
        transition any => :error
      end

      event :pause do
        transition %i[online_idle online_busy] => :paused
      end

      event :resume do
        transition paused: :connecting
      end
    end

    # Instance methods
    def bot_instance
      @bot_instance ||= bot_class.constantize.new(client) if running?
    end

    def client
      @client ||= if access_token.present?
                    ActiveMatrix::Client.new(homeserver, access_token: access_token)
                  else
                    ActiveMatrix::Client.new(homeserver)
                  end
    end

    def running?
      %i[online_idle online_busy].include?(state.to_sym)
    end

    def memory
      @memory ||= ActiveMatrix::Memory::AgentMemory.new(self)
    end

    def increment_messages_handled!
      update!(messages_handled: messages_handled + 1)
    end

    def update_activity!
      update(last_active_at: Time.current)
    end

    # Password handling
    attr_accessor :password

    def authenticate(password)
      return false if encrypted_password.blank?

      BCrypt::Password.new(encrypted_password) == password
    end

    private

    def password_changed?
      password.present?
    end

    def encrypt_password
      self.encrypted_password = BCrypt::Password.create(password) if password.present?
    end

    def valid_bot_class?
      return false if bot_class.blank?

      begin
        klass = bot_class.constantize
        errors.add(:bot_class, 'must inherit from ActiveMatrix::Bot::Base') unless klass < ActiveMatrix::Bot::Base
      rescue NameError
        errors.add(:bot_class, 'must be a valid class name')
      end
    end
  end
end
