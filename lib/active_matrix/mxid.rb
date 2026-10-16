# frozen_string_literal: true

module ActiveMatrix
  # A Matrix identifier: user id, room id, room alias or event id, parsed by
  # the spec's grammar.
  #
  # Room ids from room version 12 and event ids from room version 3 have no
  # server part: they are hashes. Server names may be DNS names, IPv4, or
  # bracketed IPv6, each with an optional port.
  class MXID
    SIGILS = { '@' => :user_id, '!' => :room_id, '#' => :room_alias, '$' => :event_id }.freeze
    MAX_LENGTH = 255

    HOST = /(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)/
    SERVER_NAME = /(?<host>#{HOST})(?::(?<port>\d{1,5}))?/
    WITH_SERVER = /\A(?<sigil>[@!#$])(?<localpart>[^:\s]+):#{SERVER_NAME}\z/
    # Room v12 room ids and room v3+ event ids: a hash, base64 (v3) or
    # URL-safe base64 (v4 and later), without padding.
    HASH_ONLY = %r{\A(?<sigil>[!$])(?<localpart>[A-Za-z0-9+/_-]{43,44})\z}

    attr_reader :sigil, :localpart, :host, :port

    def self.parse(identifier) = new(identifier)

    def self.valid?(identifier)
      new(identifier)
      true
    rescue ArgumentError
      false
    end

    def initialize(identifier)
      identifier = identifier.to_s
      raise ArgumentError, 'Matrix identifier is too long' if identifier.bytesize > MAX_LENGTH

      match = WITH_SERVER.match(identifier) || HASH_ONLY.match(identifier)
      raise ArgumentError, "not a Matrix identifier: #{identifier.inspect}" unless match

      @sigil = match[:sigil]
      @localpart = match[:localpart]
      @host = match.names.include?('host') ? match[:host] : nil
      @port = match.names.include?('port') && match[:port] ? Integer(match[:port], 10) : nil
      raise ArgumentError, "port out of range in #{identifier.inspect}" if @port && !@port.between?(1, 65_535)
    end

    def type = SIGILS.fetch(sigil)

    # host[:port], or nil for an identifier without a server part.
    def server_name
      return unless host

      port ? "#{host}:#{port}" : host
    end

    def user? = type == :user_id
    def room_id? = type == :room_id
    def room_alias? = type == :room_alias
    def room? = room_id? || room_alias?
    def event? = type == :event_id

    def to_s = server_name ? "#{sigil}#{localpart}:#{server_name}" : "#{sigil}#{localpart}"
    alias to_str to_s

    def ==(other) = other.to_s == to_s
    alias eql? ==

    delegate :hash, to: :to_s

    def inspect = "#<#{self.class.name} #{self}>"
  end
end
