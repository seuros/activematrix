# frozen_string_literal: true

# Room state as each agent sees it, written by the daemon from /sync and read
# by Rails. One copy per agent: two agents in the same room can see different
# state (membership, history visibility).
class CreateActiveMatrixRoomMirror < ActiveRecord::Migration[8.1]
  def change
    create_table :active_matrix_rooms, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.references :agent, null: false, type: :uuid, index: false,
                           foreign_key: { to_table: :active_matrix_agents, on_delete: :cascade }
      t.string :room_id, null: false
      t.string :membership, null: false
      t.string :name
      t.string :topic
      t.string :canonical_alias
      t.string :avatar_url
      t.string :room_type
      t.boolean :encrypted, null: false, default: false
      t.boolean :direct, null: false, default: false
      t.integer :joined_member_count, null: false, default: 0
      t.integer :invited_member_count, null: false, default: 0
      t.timestamps default: -> { 'now()' }
    end
    add_index :active_matrix_rooms, %i[agent_id room_id], unique: true

    create_table :active_matrix_room_members, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.uuid :agent_id, null: false
      t.string :room_id, null: false
      t.string :user_id, null: false
      t.string :membership, null: false
      t.string :display_name
      t.string :avatar_url
      t.timestamps default: -> { 'now()' }
    end
    add_index :active_matrix_room_members, %i[agent_id room_id user_id], unique: true,
                                                                         name: 'index_active_matrix_room_members_key'
    add_foreign_key :active_matrix_room_members, :active_matrix_rooms,
                    column: %i[agent_id room_id], primary_key: %i[agent_id room_id], on_delete: :cascade

    create_table :active_matrix_room_state, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.uuid :agent_id, null: false
      t.string :room_id, null: false
      t.string :event_type, null: false
      t.string :state_key, null: false, default: ''
      t.string :event_id
      t.string :sender
      t.jsonb :content, null: false, default: {}
      t.timestamps default: -> { 'now()' }
    end
    add_index :active_matrix_room_state, %i[agent_id room_id event_type state_key],
              unique: true, name: 'index_active_matrix_room_state_key'
    add_foreign_key :active_matrix_room_state, :active_matrix_rooms,
                    column: %i[agent_id room_id], primary_key: %i[agent_id room_id], on_delete: :cascade
  end
end
