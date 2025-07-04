# frozen_string_literal: true

module ActiveMatrix
  class KnowledgeBase < ApplicationRecord
    self.table_name = 'active_matrix_knowledge_bases'

    validates :key, presence: true, uniqueness: true

    scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
    scope :expired, -> { where(expires_at: ..Time.current) }
    scope :by_category, ->(category) { where(category: category) }
    scope :readable, -> { where(public_read: true) }
    scope :writable, -> { where(public_write: true) }

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def readable_by?(agent)
      public_read || (agent.is_a?(ActiveMatrix::Agent) && agent.admin?)
    end

    def writable_by?(agent)
      public_write || (agent.is_a?(ActiveMatrix::Agent) && agent.admin?)
    end

    # Cache integration
    def cache_key
      "global/#{key}"
    end

    def write_to_cache
      return unless active?

      ttl = expires_at.present? ? expires_at - Time.current : nil
      Rails.cache.write(cache_key, value, expires_in: ttl)
    end

    def self.get(key)
      # Try cache first
      cached = Rails.cache.read("global/#{key}")
      return cached if cached.present?

      # Fallback to database
      memory = find_by(key: key)
      return unless memory&.active?

      memory.write_to_cache
      memory.value
    end

    def self.set(key, value, category: nil, expires_in: nil, public_read: true, public_write: false)
      memory = find_or_initialize_by(key: key)
      memory.value = value
      memory.category = category
      memory.expires_at = expires_in.present? ? Time.current + expires_in : nil
      memory.public_read = public_read
      memory.public_write = public_write
      memory.save!
      memory.write_to_cache
      memory
    end

    def self.cleanup_expired!
      expired.destroy_all
    end

    private

    def active?
      !expired?
    end
  end
end
