# frozen_string_literal: true

class CreateConversationContexts < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :conversation_contexts do |t|
      t.references :matrix_agent, null: false, foreign_key: true
      t.string :user_id, null: false
      t.string :room_id, null: false
      t.jsonb :context, default: {}
      t.jsonb :message_history, default: { messages: [] }
      t.datetime :last_message_at
      t.integer :message_count, default: 0
      
      t.timestamps
      
      t.index [:matrix_agent_id, :user_id, :room_id], unique: true, name: 'idx_conv_context_unique'
      t.index :last_message_at
      t.index :room_id
    end
  end
end