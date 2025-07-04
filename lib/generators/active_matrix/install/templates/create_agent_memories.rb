# frozen_string_literal: true

class CreateAgentMemories < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :agent_memories do |t|
      t.references :matrix_agent, null: false, foreign_key: true
      t.string :key, null: false
      t.jsonb :value, default: {}
      t.datetime :expires_at
      
      t.timestamps
      
      t.index [:matrix_agent_id, :key], unique: true
      t.index :expires_at
    end
  end
end