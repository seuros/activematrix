# frozen_string_literal: true

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
