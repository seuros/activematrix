# frozen_string_literal: true

# The daemon <-> Rails contract.
#
# Inbox: events the daemon ingested from /sync, in the order it saw them (the
# bigserial id). Rails handles each exactly once and stamps processed_at in
# the handler's own transaction.
#
# Outbox: what Rails wants sent. The row id is the Matrix transaction id, so a
# retried send can never post twice.
class CreateActiveMatrixInboxAndOutbox < ActiveRecord::Migration[8.1]
  OUTBOX_KINDS = %w[
    send state redact join leave invite kick ban unban
    create_room typing receipt profile upload
  ].freeze
  OUTBOX_STATUSES = %w[pending sending sent failed].freeze

  def change
    create_table :active_matrix_inbox do |t|
      t.references :agent, null: false, type: :uuid, index: false,
                           foreign_key: { to_table: :active_matrix_agents, on_delete: :cascade }
      t.string :room_id, null: false
      t.string :event_id, null: false
      t.string :kind, null: false, default: 'timeline'
      t.string :event_type, null: false
      t.string :sender, null: false
      t.string :state_key
      t.jsonb :content, null: false, default: {}
      t.jsonb :raw, null: false, default: {}
      t.bigint :origin_server_ts
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.datetime :processed_at
      t.datetime :created_at, null: false, default: -> { 'now()' }
      t.check_constraint "kind IN ('timeline', 'invite')", name: 'active_matrix_inbox_kind'
    end
    add_index :active_matrix_inbox, %i[agent_id event_id], unique: true
    add_index :active_matrix_inbox, %i[agent_id room_id id], where: 'processed_at IS NULL',
                                                             name: 'index_active_matrix_inbox_pending'
    add_index :active_matrix_inbox, :processed_at, where: 'processed_at IS NOT NULL'

    create_table :active_matrix_outbox, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.references :agent, null: false, type: :uuid, index: false,
                           foreign_key: { to_table: :active_matrix_agents, on_delete: :cascade }
      t.string :kind, null: false
      t.string :room_id
      t.jsonb :payload, null: false, default: {}
      t.binary :blob
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.jsonb :result
      t.text :last_error
      t.datetime :sent_at
      t.timestamps
      t.check_constraint "kind IN (#{OUTBOX_KINDS.map { "'#{it}'" }.join(', ')})", name: 'active_matrix_outbox_kind'
      t.check_constraint "status IN (#{OUTBOX_STATUSES.map { "'#{it}'" }.join(', ')})",
                         name: 'active_matrix_outbox_status'
    end
    add_index :active_matrix_outbox, %i[agent_id created_at], where: "status = 'pending'",
                                                              name: 'index_active_matrix_outbox_pending'
    add_index :active_matrix_outbox, :sent_at, where: 'sent_at IS NOT NULL'

    create_table :active_matrix_agent_messages, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.references :from_agent, type: :uuid,
                                foreign_key: { to_table: :active_matrix_agents, on_delete: :nullify }
      t.references :to_agent, null: false, type: :uuid,
                              foreign_key: { to_table: :active_matrix_agents, on_delete: :cascade }
      t.string :topic, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :processed_at
      t.datetime :created_at, null: false, default: -> { 'now()' }
    end
  end
end
