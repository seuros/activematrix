# frozen_string_literal: true

class CreateGlobalMemories < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :global_memories do |t|
      t.string :key, null: false
      t.jsonb :value, default: {}
      t.string :category
      t.datetime :expires_at
      t.boolean :public_read, default: true
      t.boolean :public_write, default: false
      
      t.timestamps
      
      t.index :key, unique: true
      t.index :category
      t.index :expires_at
    end
  end
end