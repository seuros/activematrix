# frozen_string_literal: true

require 'open3'
require_relative 'http_json'

module SystemTests
  # activematrix-fakehs, driven through its admin API under /_fake/. Every
  # test starts its own, so tests share nothing on the Matrix side.
  #
  # Sync is scripted: what a user should see next is queued for them, and
  # their long-poll returns it.
  class FakeHomeserver
    include HttpJson

    attr_reader :url

    def self.start
      stdin, stdout, process = Open3.popen2(Binaries.fakehs, '127.0.0.1:0', err: File::NULL)
      line = stdout.gets or raise 'activematrix-fakehs exited before it was listening'
      new(JSON.parse(line).fetch('url'), stdin, process)
    end

    def initialize(url, stdin, process)
      @url = url
      @stdin = stdin
      @process = process
    end

    # It exits when its stdin closes.
    def stop
      @stdin.close
      return if @process.join(5)

      Process.kill('KILL', @process.pid)
      @process.join
    end

    def fake? = true

    def register(localpart)
      body = request(:post, '/_fake/users', { localpart: })
      User.new(body.fetch('user_id'), body.fetch('access_token'))
    end

    # A new room `owner` invites `bot` to; the invite reaches the bot on its
    # next sync.
    def room(owner, bot)
      room_id = "!#{SecureRandom.hex(6)}:matrix.test"
      member = { type: 'm.room.member', state_key: bot.user_id, sender: owner.user_id,
                 content: { membership: 'invite' } }
      push(bot, rooms: { invite: { room_id => { invite_state: { events: [member] } } } })
      room_id
    end

    def joined?(bot, room_id)
      requests.any? do |seen|
        seen['method'] == 'POST' && seen['user_id'] == bot.user_id &&
          CGI.unescapeURIComponent(seen['path']).end_with?("/join/#{room_id}")
      end
    end

    # A text message from `from`, delivered on `to`'s next sync.
    def say(from, room_id, body, to:)
      event = { type: 'm.room.message', event_id: "$#{SecureRandom.hex(8)}", sender: from.user_id,
                origin_server_ts: (Time.now.to_f * 1000).to_i, content: { msgtype: 'm.text', body: } }
      push(to, rooms: { join: { room_id => { timeline: { events: [event] } } } })
    end

    # Bodies of the messages `sender` sent to the room, oldest first.
    def messages(room_id, sender:)
      request(:get, '/_fake/sent').filter_map do |sent|
        next unless sent['room_id'] == room_id && sent['user_id'] == sender.user_id
        next unless sent['event_type'] == 'm.room.message'

        sent.dig('content', 'body')
      end
    end

    def revoke(user) = request(:post, '/_fake/revoke', { token: user.access_token })

    # Answers the next request matching `method` and `path_prefix` (encoded)
    # with the fault: status:, errcode:, retry_after_ms:, retry_after_secs:.
    def fault(method:, path_prefix:, **fault) = request(:post, '/_fake/faults', { method:, path_prefix:, **fault })

    # Every request the server saw: method, path (encoded), query, user_id, body.
    def requests = request(:get, '/_fake/requests')

    private

    def push(user, batch) = request(:post, "/_fake/sync/#{encode(user.user_id)}", batch)
  end
end
