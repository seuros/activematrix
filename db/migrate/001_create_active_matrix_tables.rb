# frozen_string_literal: true

class CreateActiveMatrixTables < ActiveRecord::Migration[8.0]
  def change
    # Matrix Agents table - main agent records with state machine
    create_table :matrix_agents do |t|
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

    add_index :matrix_agents, :state
    add_index :matrix_agents, :homeserver

    # Agent Memory table - per-agent key-value storage
    create_table :agent_memories do |t|
      t.references :matrix_agent, null: false, foreign_key: true
      t.string :key, null: false
      t.json :value # JSON serialized data
      t.datetime :expires_at
      t.timestamps
    end

    add_index :agent_memories, [:matrix_agent_id, :key], unique: true
    add_index :agent_memories, :expires_at

    # Conversation Context table - per-user/room conversation state
    create_table :conversation_contexts do |t|
      t.references :matrix_agent, null: false, foreign_key: true
      t.string :user_id, null: false
      t.string :room_id, null: false
      t.json :context # JSON context data
      t.json :message_history # JSON message history
      t.datetime :last_message_at
      t.integer :message_count, default: 0, null: false
      t.timestamps
    end

    add_index :conversation_contexts, [:matrix_agent_id, :user_id, :room_id], 
              unique: true, name: 'index_conversation_contexts_on_agent_user_room'
    add_index :conversation_contexts, :last_message_at

    # Global Memory table - shared storage across all agents
    create_table :global_memories do |t|
      t.string :key, null: false, index: { unique: true }
      t.json :value # JSON serialized data
      t.string :category
      t.datetime :expires_at
      t.boolean :public_read, default: true, null: false
      t.boolean :public_write, default: false, null: false
      t.timestamps
    end

    add_index :global_memories, :category
    add_index :global_memories, :expires_at
    add_index :global_memories, :public_read
    add_index :global_memories, :public_write
  end
end