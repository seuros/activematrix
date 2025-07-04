# frozen_string_literal: true

class CreateMatrixAgents < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :matrix_agents do |t|
      t.string :name, null: false
      t.string :homeserver, null: false
      t.string :username, null: false
      t.string :encrypted_password
      t.string :access_token
      t.string :state, default: 'offline', null: false
      t.string :bot_class, null: false
      t.jsonb :settings, default: {}
      t.string :last_sync_token
      t.datetime :last_active_at
      t.integer :rooms_count, default: 0
      t.integer :messages_handled, default: 0
      
      t.timestamps
      
      t.index :name, unique: true
      t.index :state
      t.index [:homeserver, :username]
    end
  end
end