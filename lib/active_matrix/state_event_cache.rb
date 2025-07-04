# frozen_string_literal: true

module ActiveMatrix
  class StateEventCache
    extend ActiveMatrix::Extensions
    include Enumerable

    attr_reader :room

    attr_accessor :cache_time

    ignore_inspect :client, :room

    def initialize(room, cache_time: 30 * 60, **_params)
      raise ArgumentError, 'Must be given a Room instance' unless room.is_a? ActiveMatrix::Room

      @room = room
      @cache_time = cache_time
    end

    delegate :client, to: :@room

    def reload!
      # Clear all cache entries for this room's state
      cache.delete_matched("activematrix:room:#{room.id}:state:*")
    end

    def keys
      # State is not enumerable when using Rails.cache
      # This would require keeping track of keys separately
      []
    end

    def values
      []
    end

    def size
      keys.count
    end

    def key?(type, key = nil)
      cache.exist?(cache_key(type, key))
    end

    def expire(type, key = nil)
      cache.delete(cache_key(type, key))
    end

    def each(live: false)
      to_enum(__method__, live: live) { 0 } unless block_given?
      # Not enumerable with Rails.cache
    end

    def delete(type, key = nil)
      type = type.to_s unless type.is_a? String
      client.api.set_room_state(room.id, type, {}, **{ state_key: key }.compact)
      cache.delete(cache_key(type, key))
    end

    def [](type, key = nil)
      type = type.to_s unless type.is_a? String
      return fetch_state(type, key) if client.cache == :none

      begin
        cached_value = cache.fetch(cache_key(type, key), expires_in: @cache_time) do
          result = fetch_state(type, key)

          # Convert Response objects to plain hashes for caching
          # Response objects extend Hash but contain an @api instance variable that can't be serialized
          if result.is_a?(Hash)
            # Create a clean hash with just the data, no instance variables or extended modules
            # Deep convert to ensure no mock objects are included
            clean_hash = {}
            result.each do |key, value|
              clean_hash[key] = case value
                                when Hash then value.to_h
                                when Array then value.map { |v| v.is_a?(Hash) ? v.to_h : v }
                                else value
                                end
            end
            clean_hash
          else
            result
          end
        end

        # If it's a hash and we have an API client, convert it back to a Response
        if cached_value.is_a?(Hash) && !cached_value.empty? && client.respond_to?(:api)
          ActiveMatrix::Response.new(client.api, cached_value)
        else
          cached_value
        end
      rescue StandardError
        # If caching fails, return the direct result
        fetch_state(type, key)
      end
    end

    def fetch_state(type, key = nil)
      client.api.get_room_state(room.id, type, **{ key: key }.compact)
    rescue ActiveMatrix::MatrixNotFoundError
      {}
    end

    def []=(type, key = nil, value) # rubocop:disable Style/OptionalArguments Not possible to put optional last
      type = type.to_s unless type.is_a? String
      client.api.set_room_state(room.id, type, value, **{ state_key: key }.compact)

      # Convert to plain hash for caching to avoid serialization issues with Mocha
      cacheable_value = if value.is_a?(Hash)
                          clean_hash = {}
                          value.each do |k, v|
                            clean_hash[k] = case v
                                            when Hash then v.to_h
                                            when Array then v.map { |item| item.is_a?(Hash) ? item.to_h : item }
                                            else v
                                            end
                          end
                          clean_hash
                        else
                          value
                        end
      cache.write(cache_key(type, key), cacheable_value, expires_in: @cache_time)
    end

    # Alias for writing without API call
    def write(type, value, key = nil)
      type = type.to_s unless type.is_a? String

      # Convert to plain hash for caching to avoid serialization issues
      cacheable_value = if value.is_a?(Hash)
                          clean_hash = {}
                          value.each do |k, v|
                            clean_hash[k] = case v
                                            when Hash then v.to_h
                                            when Array then v.map { |item| item.is_a?(Hash) ? item.to_h : item }
                                            else v
                                            end
                          end
                          clean_hash
                        else
                          value
                        end
      cache.write(cache_key(type, key), cacheable_value, expires_in: @cache_time)
    end

    private

    def cache_key(type, key = nil)
      "activematrix:room:#{room.id}:state:#{type}#{"|#{key}" if key}"
    end

    def cache
      ::Rails.cache
    end
  end
end
