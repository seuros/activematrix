# frozen_string_literal: true

module ActiveMatrix
  module Util
    # Provides caching functionality for Matrix objects
    # Handles serialization/deserialization to work with Rails.cache
    module Cacheable
      extend ActiveSupport::Concern

      included do
        attr_accessor :cached_at
      end

      class_methods do
        # Reconstruct object from cached data
        def from_cache(client, data)
          return nil unless data.is_a?(Hash) && data[:_cache_class] == name

          # Remove cache metadata
          attrs = data.except(:_cache_class, :_cached_at)

          # Reconstruct based on class type
          case name
          when 'ActiveMatrix::User'
            new(client, attrs[:id], attrs.except(:id))
          when 'ActiveMatrix::Room'
            new(client, attrs[:id], attrs.except(:id))
          else
            new(client, attrs)
          end
        end
      end

      # Convert object to cacheable hash
      def to_cache
        data = cache_attributes.merge(
          _cache_class: self.class.name,
          _cached_at: Time.current
        )

        # Ensure we only cache serializable data
        data.deep_stringify_keys
      end

      # Override in each class to specify what to cache
      def cache_attributes
        if respond_to?(:attributes)
          attributes
        elsif respond_to?(:to_h)
          to_h
        else
          {}
        end
      end

      # Generate a cache key for this object
      def cache_key(*suffixes)
        base_key = "#{self.class.name.underscore}:#{cache_id}"
        suffixes.any? ? "#{base_key}:#{suffixes.join(':')}" : base_key
      end

      # Override in each class if ID method is different
      def cache_id
        respond_to?(:id) ? id : object_id
      end

      # Check if this object was loaded from cache
      def from_cache?
        @cached_at.present?
      end
    end
  end
end
