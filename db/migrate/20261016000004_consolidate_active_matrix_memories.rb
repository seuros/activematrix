# frozen_string_literal: true

# One key-value table for every memory tier:
#   global        agent_id NULL,  chat_session_id NULL
#   agent         agent_id set,   chat_session_id NULL
#   conversation  chat_session_id set (agent_id too, for cleanup)
#
# Replaces agent_stores, knowledge_bases and chat_sessions.context. Message
# history is no longer copied into chat sessions: the inbox is the history.
class ConsolidateActiveMatrixMemories < ActiveRecord::Migration[8.1]
  def up
    create_table :active_matrix_memories, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.references :agent, type: :uuid, index: false,
                           foreign_key: { to_table: :active_matrix_agents, on_delete: :cascade }
      t.references :chat_session, type: :uuid, index: false,
                                  foreign_key: { to_table: :active_matrix_chat_sessions, on_delete: :cascade }
      t.string :key, null: false
      t.jsonb :value, null: false
      t.datetime :expires_at
      t.timestamps
    end
    add_index :active_matrix_memories, %i[agent_id chat_session_id key], unique: true, nulls_not_distinct: true,
                                                                         name: 'index_active_matrix_memories_key'
    add_index :active_matrix_memories, :chat_session_id, where: 'chat_session_id IS NOT NULL'
    add_index :active_matrix_memories, :expires_at, where: 'expires_at IS NOT NULL'

    execute <<~SQL.squish
      INSERT INTO active_matrix_memories (agent_id, key, value, expires_at, created_at, updated_at)
      SELECT agent_id, key, COALESCE(value, 'null'), expires_at, created_at, updated_at
      FROM active_matrix_agent_stores
    SQL
    execute <<~SQL.squish
      INSERT INTO active_matrix_memories (key, value, expires_at, created_at, updated_at)
      SELECT key, COALESCE(value, 'null'), expires_at, created_at, updated_at
      FROM active_matrix_knowledge_bases
    SQL
    execute <<~SQL.squish
      INSERT INTO active_matrix_memories (agent_id, chat_session_id, key, value, created_at, updated_at)
      SELECT cs.agent_id, cs.id, kv.key, kv.value, cs.created_at, cs.updated_at
      FROM active_matrix_chat_sessions cs, jsonb_each(COALESCE(cs.context, '{}')) kv
    SQL

    drop_table :active_matrix_agent_stores
    drop_table :active_matrix_knowledge_bases

    remove_index :active_matrix_chat_sessions, :agent_id
    remove_index :active_matrix_chat_sessions, :room_id
    remove_foreign_key :active_matrix_chat_sessions, :active_matrix_agents, column: :agent_id
    add_foreign_key :active_matrix_chat_sessions, :active_matrix_agents, column: :agent_id, on_delete: :cascade
    change_table :active_matrix_chat_sessions, bulk: true do |t|
      t.remove :context, :message_history
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'agent_stores and knowledge_bases were folded into memories'
  end
end
