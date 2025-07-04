# frozen_string_literal: true

class CreateActiveMatrixTables < ActiveRecord::Migration[8.0]
  def change
    # Agents table - main agent records with state machine
    create_table :active_matrix_agents do |t|
      t.string :name, null: false, index: { unique: true }
      t.string :homeserver, null: false
      t.string :username, null: false
      t.string :bot_class, null: false
      t.string :state, default: 'offline', null: false
      t.string :access_token
      t.string :encrypted_password
      t.json :settings # JSON settings for the bot
      t.string :last_sync_token
      t.datetime :last_active_at
      t.integer :messages_handled, default: 0, null: false
      t.timestamps
    end

    add_index :active_matrix_agents, :state
    add_index :active_matrix_agents, :homeserver

    # Agent Store table - per-agent key-value storage
    create_table :active_matrix_agent_stores do |t|
      t.references :agent, null: false, foreign_key: { to_table: :active_matrix_agents }
      t.string :key, null: false
      t.json :value # JSON serialized data
      t.datetime :expires_at
      t.timestamps
    end

    add_index :active_matrix_agent_stores, %i[agent_id key], unique: true
    add_index :active_matrix_agent_stores, :expires_at

    # Chat Session table - per-user/room conversation state
    create_table :active_matrix_chat_sessions do |t|
      t.references :agent, null: false, foreign_key: { to_table: :active_matrix_agents }
      t.string :user_id, null: false
      t.string :room_id, null: false
      t.json :context # JSON context data
      t.json :message_history # JSON message history
      t.datetime :last_message_at
      t.integer :message_count, default: 0, null: false
      t.timestamps
    end

    add_index :active_matrix_chat_sessions, %i[agent_id user_id room_id],
              unique: true, name: 'index_chat_sessions_on_agent_user_room'
    add_index :active_matrix_chat_sessions, :last_message_at

    # Knowledge Base table - shared storage across all agents
    create_table :active_matrix_knowledge_bases do |t|
      t.string :key, null: false, index: { unique: true }
      t.json :value # JSON serialized data
      t.string :category
      t.datetime :expires_at
      t.boolean :public_read, default: true, null: false
      t.boolean :public_write, default: false, null: false
      t.timestamps
    end

    add_index :active_matrix_knowledge_bases, :category
    add_index :active_matrix_knowledge_bases, :expires_at
    add_index :active_matrix_knowledge_bases, :public_read
    add_index :active_matrix_knowledge_bases, :public_write
  end
end
