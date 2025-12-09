# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 1) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_matrix_agent_stores", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "key", null: false
    t.json "value"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "key"], name: "index_active_matrix_agent_stores_on_agent_id_and_key", unique: true
    t.index ["agent_id"], name: "index_active_matrix_agent_stores_on_agent_id"
    t.index ["expires_at"], name: "index_active_matrix_agent_stores_on_expires_at"
  end

  create_table "active_matrix_agents", force: :cascade do |t|
    t.string "name", null: false
    t.string "homeserver", null: false
    t.string "username", null: false
    t.string "bot_class", null: false
    t.string "state", default: "offline", null: false
    t.string "access_token"
    t.string "encrypted_password"
    t.json "settings"
    t.string "last_sync_token"
    t.datetime "last_active_at"
    t.integer "messages_handled", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["homeserver"], name: "index_active_matrix_agents_on_homeserver"
    t.index ["name"], name: "index_active_matrix_agents_on_name", unique: true
    t.index ["state"], name: "index_active_matrix_agents_on_state"
  end

  create_table "active_matrix_chat_sessions", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "user_id", null: false
    t.string "room_id", null: false
    t.json "context"
    t.json "message_history"
    t.datetime "last_message_at"
    t.integer "message_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "user_id", "room_id"], name: "index_chat_sessions_on_agent_user_room", unique: true
    t.index ["agent_id"], name: "index_active_matrix_chat_sessions_on_agent_id"
    t.index ["last_message_at"], name: "index_active_matrix_chat_sessions_on_last_message_at"
  end

  create_table "active_matrix_knowledge_bases", force: :cascade do |t|
    t.string "key", null: false
    t.json "value"
    t.string "category"
    t.datetime "expires_at"
    t.boolean "public_read", default: true, null: false
    t.boolean "public_write", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_active_matrix_knowledge_bases_on_category"
    t.index ["expires_at"], name: "index_active_matrix_knowledge_bases_on_expires_at"
    t.index ["key"], name: "index_active_matrix_knowledge_bases_on_key", unique: true
    t.index ["public_read"], name: "index_active_matrix_knowledge_bases_on_public_read"
    t.index ["public_write"], name: "index_active_matrix_knowledge_bases_on_public_write"
  end

  add_foreign_key "active_matrix_agent_stores", "active_matrix_agents", column: "agent_id"
  add_foreign_key "active_matrix_chat_sessions", "active_matrix_agents", column: "agent_id"
end
