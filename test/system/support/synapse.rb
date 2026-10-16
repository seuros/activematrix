# frozen_string_literal: true

require 'openssl'
require_relative 'http_json'

module SystemTests
  # A real Synapse, for the contract tier (docker compose --profile contract).
  # Accounts come from shared-secret registration; every test registers its
  # own, with random localparts, so tests share the server but nothing on it.
  class Synapse
    include HttpJson

    attr_reader :url

    def initialize(url, shared_secret)
      @url = url
      @shared_secret = shared_secret
      @owners = {}
    end

    def stop; end

    def fake? = false

    def register(localpart)
      path = '/_synapse/admin/v1/register'
      nonce = request(:get, path).fetch('nonce')
      password = SecureRandom.hex(16)
      mac = OpenSSL::HMAC.hexdigest('SHA1', @shared_secret, [nonce, localpart, password, 'notadmin'].join("\0"))
      body = request(:post, path, { nonce:, username: localpart, password:, admin: false, mac: })
      User.new(body.fetch('user_id'), body.fetch('access_token'))
    end

    def room(owner, bot)
      room_id = post(owner, '/_matrix/client/v3/createRoom', { preset: 'private_chat', invite: [bot.user_id] })
                .fetch('room_id')
      @owners[room_id] = owner
      room_id
    end

    def joined?(bot, room_id)
      get(@owners.fetch(room_id), "/_matrix/client/v3/rooms/#{encode(room_id)}/joined_members")
        .fetch('joined').key?(bot.user_id)
    end

    # `to:` is for fakehs; Synapse delivers to every member.
    def say(from, room_id, body, **)
      put(from, "/_matrix/client/v3/rooms/#{encode(room_id)}/send/m.room.message/#{SecureRandom.hex(8)}",
          { msgtype: 'm.text', body: })
    end

    # Bodies of the messages `sender` sent to the room, oldest first, read by
    # the room's owner.
    def messages(room_id, sender:)
      chunk = get(@owners.fetch(room_id), "/_matrix/client/v3/rooms/#{encode(room_id)}/messages?dir=b&limit=100")
              .fetch('chunk')
      chunk.reverse.filter_map do |event|
        event.dig('content', 'body') if event['type'] == 'm.room.message' && event['sender'] == sender.user_id
      end
    end

    # Logs the session out, which is what a revoked token is.
    def revoke(user) = post(user, '/_matrix/client/v3/logout', {})

    private

    def get(user, path) = request(:get, path, token: user.access_token)
    def post(user, path, body) = request(:post, path, body, token: user.access_token)
    def put(user, path, body) = request(:put, path, body, token: user.access_token)
  end
end
