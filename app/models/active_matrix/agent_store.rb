# frozen_string_literal: true

# <rails-lens:schema:begin>
# table = "active_matrix_agent_stores"
# database_dialect = "PostgreSQL"
#
# columns = [
#   { name = "id", type = "integer", pk = true, null = false },
#   { name = "agent_id", type = "integer", null = false },
#   { name = "key", type = "string", null = false },
#   { name = "value", type = "json" },
#   { name = "expires_at", type = "datetime" },
#   { name = "created_at", type = "datetime", null = false },
#   { name = "updated_at", type = "datetime", null = false }
# ]
#
# indexes = [
#   { name = "index_active_matrix_agent_stores_on_agent_id", columns = ["agent_id"] },
#   { name = "index_active_matrix_agent_stores_on_agent_id_and_key", columns = ["agent_id", "key"], unique = true },
#   { name = "index_active_matrix_agent_stores_on_expires_at", columns = ["expires_at"] }
# ]
#
# foreign_keys = [
#   { column = "agent_id", references_table = "active_matrix_agents", references_column = "id", name = "fk_rails_59b3dc556f" }
# ]
#
# [callbacks]
# after_commit = [{ method = "schedule_cleanup", if = ["expires_at?"] }]
#
# notes = ["agent:INVERSE_OF", "value:NOT_NULL", "key:LIMIT"]
# <rails-lens:schema:end>
module ActiveMatrix
  class AgentStore < ApplicationRecord
    self.table_name = 'active_matrix_agent_stores'

    belongs_to :agent, class_name: 'ActiveMatrix::Agent'

    validates :key, presence: true, uniqueness: { scope: :agent_id }

    scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
    scope :expired, -> { where(expires_at: ..Time.current) }

    # Automatically clean up expired memories
    after_commit :schedule_cleanup, if: :expires_at?

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def ttl=(seconds)
      self.expires_at = seconds.present? ? Time.current + seconds : nil
    end

    def ttl
      return nil if expires_at.blank?

      remaining = expires_at - Time.current
      [remaining, 0].max
    end

    # Cache integration
    def cache_key
      "agent_memory/#{agent_id}/#{key}"
    end

    def write_to_cache
      Rails.cache.write(cache_key, value, expires_in: ttl)
    end

    def self.cleanup_expired!
      expired.destroy_all
    end

    private

    def schedule_cleanup
      ActiveMatrix::Agent::Jobs::MemoryReaper.set(wait_until: expires_at).perform_later if defined?(ActiveMatrix::Agent::Jobs::MemoryReaper)
    end
  end
end
