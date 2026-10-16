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

ActiveRecord::Schema[8.1].define(version: 2026_10_16_000004) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "active_matrix_agent_messages", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "from_agent_id"
    t.uuid "to_agent_id", null: false
    t.string "topic", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.index ["from_agent_id"], name: "index_active_matrix_agent_messages_on_from_agent_id"
    t.index ["to_agent_id"], name: "index_active_matrix_agent_messages_on_to_agent_id"
  end

  create_table "active_matrix_agents", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "homeserver_url", null: false
    t.string "bot_class", null: false
    t.string "state", default: "offline", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "sync_token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.string "device_id"
    t.binary "access_token_ciphertext"
    t.boolean "enabled", default: true, null: false
    t.text "last_error"
    t.datetime "last_error_at"
    t.datetime "heartbeat_at"
    t.string "claimed_by"
    t.datetime "lease_expires_at"
    t.index ["name"], name: "index_active_matrix_agents_on_name", unique: true
    t.index ["state"], name: "index_active_matrix_agents_on_state"
    t.check_constraint "state::text = ANY (ARRAY['offline'::character varying, 'starting'::character varying, 'online'::character varying, 'reconnecting'::character varying, 'failed'::character varying]::text[])", name: "active_matrix_agents_state"
  end

  create_table "active_matrix_chat_sessions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.string "user_id", null: false
    t.string "room_id", null: false
    t.datetime "last_message_at"
    t.integer "message_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "user_id", "room_id"], name: "index_chat_sessions_on_agent_user_room", unique: true
    t.index ["last_message_at"], name: "index_active_matrix_chat_sessions_on_last_message_at"
  end

  create_table "active_matrix_inbox", force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.string "room_id", null: false
    t.string "event_id", null: false
    t.string "kind", default: "timeline", null: false
    t.string "event_type", null: false
    t.string "sender", null: false
    t.string "state_key"
    t.jsonb "content", default: {}, null: false
    t.jsonb "raw", default: {}, null: false
    t.bigint "origin_server_ts"
    t.integer "attempts", default: 0, null: false
    t.text "last_error"
    t.datetime "processed_at"
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.index ["agent_id", "event_id"], name: "index_active_matrix_inbox_on_agent_id_and_event_id", unique: true
    t.index ["agent_id", "room_id", "id"], name: "index_active_matrix_inbox_pending", where: "(processed_at IS NULL)"
    t.index ["processed_at"], name: "index_active_matrix_inbox_on_processed_at", where: "(processed_at IS NOT NULL)"
    t.check_constraint "kind::text = ANY (ARRAY['timeline'::character varying, 'invite'::character varying]::text[])", name: "active_matrix_inbox_kind"
  end

  create_table "active_matrix_memories", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.uuid "chat_session_id"
    t.string "key", null: false
    t.jsonb "value", null: false
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "chat_session_id", "key"], name: "index_active_matrix_memories_key", unique: true, nulls_not_distinct: true
    t.index ["chat_session_id"], name: "index_active_matrix_memories_on_chat_session_id", where: "(chat_session_id IS NOT NULL)"
    t.index ["expires_at"], name: "index_active_matrix_memories_on_expires_at", where: "(expires_at IS NOT NULL)"
  end

  create_table "active_matrix_outbox", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.string "kind", null: false
    t.string "room_id"
    t.jsonb "payload", default: {}, null: false
    t.binary "blob"
    t.string "status", default: "pending", null: false
    t.integer "attempts", default: 0, null: false
    t.jsonb "result"
    t.text "last_error"
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "created_at"], name: "index_active_matrix_outbox_pending", where: "((status)::text = 'pending'::text)"
    t.index ["sent_at"], name: "index_active_matrix_outbox_on_sent_at", where: "(sent_at IS NOT NULL)"
    t.check_constraint "kind::text = ANY (ARRAY['send'::character varying, 'state'::character varying, 'redact'::character varying, 'join'::character varying, 'leave'::character varying, 'invite'::character varying, 'kick'::character varying, 'ban'::character varying, 'unban'::character varying, 'create_room'::character varying, 'typing'::character varying, 'receipt'::character varying, 'profile'::character varying, 'upload'::character varying]::text[])", name: "active_matrix_outbox_kind"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'sending'::character varying, 'sent'::character varying, 'failed'::character varying]::text[])", name: "active_matrix_outbox_status"
  end

  create_table "active_matrix_room_members", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.string "room_id", null: false
    t.string "user_id", null: false
    t.string "membership", null: false
    t.string "display_name"
    t.string "avatar_url"
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["agent_id", "room_id", "user_id"], name: "index_active_matrix_room_members_key", unique: true
  end

  create_table "active_matrix_room_state", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.string "room_id", null: false
    t.string "event_type", null: false
    t.string "state_key", default: "", null: false
    t.string "event_id"
    t.string "sender"
    t.jsonb "content", default: {}, null: false
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["agent_id", "room_id", "event_type", "state_key"], name: "index_active_matrix_room_state_key", unique: true
  end

  create_table "active_matrix_rooms", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.string "room_id", null: false
    t.string "membership", null: false
    t.string "name"
    t.string "topic"
    t.string "canonical_alias"
    t.string "avatar_url"
    t.string "room_type"
    t.boolean "encrypted", default: false, null: false
    t.boolean "direct", default: false, null: false
    t.integer "joined_member_count", default: 0, null: false
    t.integer "invited_member_count", default: 0, null: false
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["agent_id", "room_id"], name: "index_active_matrix_rooms_on_agent_id_and_room_id", unique: true
  end

  add_foreign_key "active_matrix_agent_messages", "active_matrix_agents", column: "from_agent_id", on_delete: :nullify
  add_foreign_key "active_matrix_agent_messages", "active_matrix_agents", column: "to_agent_id", on_delete: :cascade
  add_foreign_key "active_matrix_chat_sessions", "active_matrix_agents", column: "agent_id", on_delete: :cascade
  add_foreign_key "active_matrix_inbox", "active_matrix_agents", column: "agent_id", on_delete: :cascade
  add_foreign_key "active_matrix_memories", "active_matrix_agents", column: "agent_id", on_delete: :cascade
  add_foreign_key "active_matrix_memories", "active_matrix_chat_sessions", column: "chat_session_id", on_delete: :cascade
  add_foreign_key "active_matrix_outbox", "active_matrix_agents", column: "agent_id", on_delete: :cascade
  add_foreign_key "active_matrix_room_members", "active_matrix_rooms", column: ["agent_id", "room_id"], primary_key: ["agent_id", "room_id"], on_delete: :cascade
  add_foreign_key "active_matrix_room_state", "active_matrix_rooms", column: ["agent_id", "room_id"], primary_key: ["agent_id", "room_id"], on_delete: :cascade
  add_foreign_key "active_matrix_rooms", "active_matrix_agents", column: "agent_id", on_delete: :cascade
end
