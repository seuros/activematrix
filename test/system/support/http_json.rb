# frozen_string_literal: true

require 'json'
require 'net/http'

module SystemTests
  # A homeserver account: what the tests talk as, and what the daemon logs in with.
  User = Data.define(:user_id, :access_token)

  # JSON over HTTP, for the homeservers' APIs.
  module HttpJson
    private

    def request(method, path, body = nil, token: nil)
      uri = URI.join(@url, path)
      klass = Net::HTTP.const_get(method.to_s.capitalize)
      req = klass.new(uri, 'Content-Type' => 'application/json')
      req['Authorization'] = "Bearer #{token}" if token
      req.body = JSON.generate(body) unless body.nil?
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { it.request(req) }
      raise "#{method.upcase} #{path}: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    end

    def encode(segment) = CGI.escapeURIComponent(segment)
  end
end
