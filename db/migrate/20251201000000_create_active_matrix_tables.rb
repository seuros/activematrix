# frozen_string_literal: true

# PostgreSQL 18+ required for UUIDv7 and other features
class CreateActiveMatrixTables < ActiveRecord::Migration[8.0]
  def change
    # Enable UUID extension
    enable_extension 'pgcrypto' unless extension_enabled?('pgcrypto')

    # Agents table - main agent records with state machine
    # Uses UUIDv7 for timestamp-sortable primary keys (PG18 feature)
    create_table :active_matrix_agents, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.string :name, null: false, index: { unique: true }
      t.string :homeserver, null: false
      t.string :username, null: false
      t.string :bot_class, null: false
      t.string :state, default: 'offline', null: false
      t.string :access_token
      t.string :encrypted_password
      t.jsonb :settings, default: {} # JSONB for better indexing/querying
      t.string :last_sync_token
      t.datetime :last_active_at
      t.integer :messages_handled, default: 0, null: false
      t.timestamps
    end

    add_index :active_matrix_agents, :state
    add_index :active_matrix_agents, :homeserver
    add_index :active_matrix_agents, :settings, using: :gin # GIN index for JSONB queries

    # Agent Store table - per-agent key-value storage
    create_table :active_matrix_agent_stores, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.references :agent, null: false, foreign_key: { to_table: :active_matrix_agents }, type: :uuid
      t.string :key, null: false
      t.jsonb :value, default: {}
      t.datetime :expires_at
      t.timestamps
    end

    add_index :active_matrix_agent_stores, %i[agent_id key], unique: true
    add_index :active_matrix_agent_stores, :expires_at, where: 'expires_at IS NOT NULL'

    # Chat Session table - per-user/room conversation state
    create_table :active_matrix_chat_sessions, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.references :agent, null: false, foreign_key: { to_table: :active_matrix_agents }, type: :uuid
      t.string :user_id, null: false
      t.string :room_id, null: false
      t.jsonb :context, default: {}
      t.jsonb :message_history, default: { 'messages' => [] }
      t.datetime :last_message_at
      t.integer :message_count, default: 0, null: false
      t.timestamps
    end

    add_index :active_matrix_chat_sessions, %i[agent_id user_id room_id],
              unique: true, name: 'index_chat_sessions_on_agent_user_room'
    add_index :active_matrix_chat_sessions, :last_message_at
    add_index :active_matrix_chat_sessions, :room_id

    # Knowledge Base table - shared storage across all agents
    create_table :active_matrix_knowledge_bases, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.string :key, null: false, index: { unique: true }
      t.jsonb :value, default: {}
      t.string :category
      t.datetime :expires_at
      t.boolean :public_read, default: true, null: false
      t.boolean :public_write, default: false, null: false
      t.timestamps
    end

    add_index :active_matrix_knowledge_bases, :category
    add_index :active_matrix_knowledge_bases, :expires_at, where: 'expires_at IS NOT NULL'
  end
end
