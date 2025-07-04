# frozen_string_literal: true

module ActiveMatrix::Util
  class AccountDataCache
    extend ActiveMatrix::Extensions
    include Enumerable

    attr_reader :client, :room

    attr_accessor :cache_time

    ignore_inspect :client, :room

    def initialize(client, room: nil, cache_time: 1 * 60 * 60, **_params)
      raise ArgumentError, 'Must be given a Client instance' unless client.is_a? ActiveMatrix::Client

      @client = client
      @cache_time = cache_time
      @tracked_keys = Set.new

      return unless room

      @room = room
      @room = client.ensure_room room unless @room.is_a? ActiveMatrix::Room
    end

    def reload!
      # Clear all cache entries for this account data
      return unless cache_available?

      if room
        cache.delete_matched("activematrix:account_data:#{client.mxid}:room:#{room.id}:*")
      else
        cache.delete_matched("activematrix:account_data:#{client.mxid}:global:*")
      end
    end

    def keys
      @tracked_keys.to_a.sort
    end

    def values
      []
    end

    def size
      keys.count
    end

    def key?(key)
      cache_available? && cache.exist?(cache_key(key))
    end

    def each(live: false)
      to_enum(__method__, live: live) { 0 } unless block_given?
      # Not enumerable with Rails.cache
    end

    def delete(key)
      key = key.to_s unless key.is_a? String
      if room
        client.api.set_room_account_data(client.mxid, room.id, key, {})
      else
        client.api.set_account_data(client.mxid, key, {})
      end
      cache.delete(cache_key(key)) if cache_available?
    end

    def [](key)
      key = key.to_s unless key.is_a? String

      # Track the key whenever it's accessed
      @tracked_keys.add(key)

      return fetch_account_data(key) unless cache_available?

      cache.fetch(cache_key(key), expires_in: @cache_time) do
        fetch_account_data(key)
      end
    end

    def fetch_account_data(key)
      if room
        client.api.get_room_account_data(client.mxid, room.id, key)
      else
        client.api.get_account_data(client.mxid, key)
      end
    rescue ActiveMatrix::MatrixNotFoundError
      {}
    end

    def []=(key, value)
      key = key.to_s unless key.is_a? String
      if room
        client.api.set_room_account_data(client.mxid, room.id, key, value)
      else
        client.api.set_account_data(client.mxid, key, value)
      end

      @tracked_keys.add(key)
      cache.write(cache_key(key), value, expires_in: @cache_time) if cache_available?
    end

    # Write data without making API call (for sync responses)
    def write(key, value)
      key = key.to_s unless key.is_a? String
      @tracked_keys.add(key)
      cache.write(cache_key(key), value, expires_in: @cache_time) if cache_available?
    end

    private

    def cache_key(key)
      if room
        "activematrix:account_data:#{client.mxid}:room:#{room.id}:#{key}"
      else
        "activematrix:account_data:#{client.mxid}:global:#{key}"
      end
    end

    def cache_available?
      defined?(::Rails) && ::Rails.respond_to?(:cache) && ::Rails.cache
    end

    def cache
      ::Rails.cache
    end
  end
end
