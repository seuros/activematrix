# frozen_string_literal: true

module ActiveMatrix
  class Memory
    # Key-value access to one memory tier. Values are anything JSON can hold.
    # Expired entries read as missing; writing one starts it afresh.
    class Store
      UNIQUE_INDEX = 'index_active_matrix_memories_key'

      # Missing or expired counts as 0; a value that is not a number raises.
      # The clock is Time.current, bound in, like every other read and write
      # here: expiry is judged by one clock, not by Ruby's and Postgres'.
      INCREMENT_SQL = <<~SQL.squish
        INSERT INTO active_matrix_memories AS m (agent_id, chat_session_id, key, value, created_at, updated_at)
        VALUES (:agent_id, :chat_session_id, :key, to_jsonb(:by::numeric), :now, :now)
        ON CONFLICT (agent_id, chat_session_id, key) DO UPDATE SET
          value = to_jsonb(CASE WHEN m.expires_at <= :now THEN 0
                                ELSE COALESCE((m.value #>> '{}')::numeric, 0) END + :by::numeric),
          expires_at = CASE WHEN m.expires_at <= :now THEN NULL ELSE m.expires_at END,
          updated_at = :now
        RETURNING value
      SQL

      def initialize(agent: nil, chat_session: nil)
        @agent_id = agent&.id
        @chat_session_id = chat_session&.id
      end

      def [](key) = fetch(key, nil)

      def fetch(key, default = nil)
        row = scope.live.find_by(key: key.to_s)
        return row.value if row

        block_given? ? yield(key) : default
      end

      def []=(key, value)
        write(key, value)
      end

      # expires_in: seconds (or a Duration) until the value reads as missing.
      # One upsert statement, so there is no read-then-write race.
      def write(key, value, expires_in: nil)
        Memory.upsert(
          { agent_id: @agent_id, chat_session_id: @chat_session_id, key: key.to_s, value:,
            expires_at: expires_in && (Time.current + expires_in) },
          unique_by: UNIQUE_INDEX
        )
        value
      end

      def key?(key) = scope.live.exists?(key: key.to_s)

      # Removes the key and returns its value, like Hash#delete.
      def delete(key)
        value = self[key]
        scope.where(key: key.to_s).delete_all
        value
      end

      def to_h = scope.live.pluck(:key, :value).to_h

      # Adds `by` to a numeric value in one statement, so concurrent
      # increments never lose an update. Returns the new value.
      def increment(key, by: 1)
        sql = Memory.sanitize_sql_array([INCREMENT_SQL, { agent_id: @agent_id, chat_session_id: @chat_session_id,
                                                          key: key.to_s, by:, now: Time.current }])
        JSON.parse(Memory.connection.select_value(sql))
      end

      private

      def scope = Memory.where(agent_id: @agent_id, chat_session_id: @chat_session_id)
    end
  end
end
