# frozen_string_literal: true

module ActiveMatrix
  module Memory
    # Base class for memory implementations
    class Base
      include ActiveMatrix::Logging

      def initialize
        @cache_enabled = Rails.cache.present? rescue false
      end

      # Get a value from memory
      def get(key)
        raise NotImplementedError
      end

      # Set a value in memory
      def set(key, value, expires_in: nil)
        raise NotImplementedError
      end

      # Check if a key exists
      def exists?(key)
        raise NotImplementedError
      end

      # Delete a key
      def delete(key)
        raise NotImplementedError
      end

      # Get multiple keys at once
      def get_multi(*keys)
        keys.to_h { |key| [key, get(key)] }
      end

      # Set multiple keys at once
      def set_multi(hash, expires_in: nil)
        hash.each { |key, value| set(key, value, expires_in: expires_in) }
      end

      # Clear all memory (use with caution)
      def clear!
        raise NotImplementedError
      end

      protected

      # Generate cache key
      def cache_key(key)
        raise NotImplementedError
      end

      # Try cache first, then database
      def fetch_with_cache(key, expires_in: nil)
        return yield unless @cache_enabled

        cached_key = cache_key(key)

        # Try cache first
        cached = Rails.cache.read(cached_key)
        return cached if cached.present?

        # Get from source
        value = yield
        return nil if value.nil?

        # Write to cache
        Rails.cache.write(cached_key, value, expires_in: expires_in)
        value
      end

      # Write through to cache and database
      def write_through(key, value, expires_in: nil)
        cached_key = cache_key(key)

        # Write to database first
        result = yield

        # Then update cache if enabled
        Rails.cache.write(cached_key, value, expires_in: expires_in) if @cache_enabled && result

        result
      end

      # Delete from cache and database
      def delete_through(key)
        cached_key = cache_key(key)

        # Delete from database
        result = yield

        # Delete from cache if enabled
        Rails.cache.delete(cached_key) if @cache_enabled

        result
      end
    end
  end
end
