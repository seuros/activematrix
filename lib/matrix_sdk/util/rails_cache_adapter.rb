# frozen_string_literal: true

module MatrixSdk
  module Util
    class RailsCacheAdapter
      attr_accessor :client

      def initialize
        @cache = ::Rails.cache
      end

      def read(key, _options = {})
        @cache.read(key)
      end

      def write(key, value, expires_in: nil)
        @cache.write(key, value, expires_in: expires_in)
      end

      def exist?(key)
        @cache.exist?(key)
      end

      def delete(key)
        @cache.delete(key)
      end

      def clear
        @cache.clear
      end

      def cleanup
        # Rails.cache handles its own cleanup
      end
    end
  end
end
