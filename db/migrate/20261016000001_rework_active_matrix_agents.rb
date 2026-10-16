# frozen_string_literal: true

# 0.1: the daemon owns credentials and runtime state; Rails owns the desired
# state (enabled) and the bot configuration.
#
# Access tokens are not carried over: 0.0.x stored them with Active Record
# encryption, which the daemon cannot read. Run `activematrix login <agent>`
# for each agent after migrating.
class ReworkActiveMatrixAgents < ActiveRecord::Migration[8.1]
  STATES = %w[offline starting online reconnecting failed].freeze

  def up
    remove_index :active_matrix_agents, :settings
    remove_index :active_matrix_agents, :homeserver
    remove_index :active_matrix_agents, :matrix_connection

    rename_column :active_matrix_agents, :homeserver, :homeserver_url
    rename_column :active_matrix_agents, :last_sync_token, :sync_token

    change_table :active_matrix_agents, bulk: true do |t|
      t.string :user_id
      t.string :device_id
      t.binary :access_token_ciphertext
      t.boolean :enabled, null: false, default: true
      t.text :last_error
      t.datetime :last_error_at
      t.datetime :heartbeat_at
      t.string :claimed_by
      t.datetime :lease_expires_at
    end

    execute <<~SQL.squish
      UPDATE active_matrix_agents SET
        user_id = CASE WHEN username LIKE '@%:%' THEN username END,
        enabled = state <> 'paused',
        state = CASE state
                  WHEN 'online_idle' THEN 'online'
                  WHEN 'online_busy' THEN 'online'
                  WHEN 'connecting' THEN 'starting'
                  WHEN 'error' THEN 'failed'
                  ELSE 'offline'
                END,
        settings = COALESCE(settings, '{}')
    SQL

    change_table :active_matrix_agents, bulk: true do |t|
      t.remove :username, :access_token, :encrypted_password, :matrix_connection,
               :last_active_at, :messages_handled
      t.change_null :settings, false
      t.change_null :homeserver_url, false
      t.check_constraint "state IN (#{STATES.map { "'#{it}'" }.join(', ')})", name: 'active_matrix_agents_state'
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, '0.0.x access tokens and passwords are not recoverable'
  end
end
