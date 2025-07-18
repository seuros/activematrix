#!/usr/bin/env ruby
# frozen_string_literal: true

# An example of a lightweight bot using the bot DSL
#
# This bot will implement a subset of the maubot ping/echo module
# It showcases required and optional parameters, as well as limitations on commands

require 'active_matrix/bot'

# Util methods added at end of class, to keep command listing near the top
module Utils; end

set :bot_name, 'examplebot'

command :spam, only: :dm, desc: 'Spams a bunch of nonsense' do |message_count = nil|
  message_count ||= 5
  message_count_i = message_count.to_i
  raise ArgumentError, 'Message count must be an integer' if message_count_i.to_s != message_count.to_s

  spam = Array.new(message_count_i) { Array.new(rand(10..30)) { rand(65..91).chr }.join }
  spam.each do |msg|
    room.send_notice(msg)
  end
end

command(:thumbsup, desc: 'Gives you a thumbs up', only: -> { room.user_can_send? client.mxid, 'm.reaction' }) do
  room.send_event 'm.reaction', {
    'm.relates_to': {
      rel_type: 'm.annotation',
      event_id: event[:event_id],
      key: '👍️'
    }
  }
end

command :echo, desc: 'Echoes the given message back as an m.notice' do |message|
  break if message.nil? # Don't echo empty requests

  logger.debug "Received !echo from #{sender}"

  room.send_notice(message)
end

command :ping, desc: 'Runs a ping with a given ID and returns the request time' do |message = nil|
  origin_ts = Time.zone.at(event[:origin_server_ts] / 1000.0)
  diff = Time.zone.now - origin_ts

  logger.info "[#{Time.zone.now.strftime '%H:%M'}] <#{sender.id} in #{room.id} @ #{(diff * 1000).round(2)}ms> #{message.inspect}"

  plaintext = '%<sender>s: Pong! (ping%<msg>s took %<time>s to arrive)'
  html = '<a href="https://matrix.to/#/%<sender>s">%<sender>s</a>: Pong! (<a href="https://matrix.to/#/%<room>s/%<event>s">ping</a>%<msg>s took %<time>s to arrive)'

  milliseconds = (diff * 1000).to_i
  message = " \"#{message}\"" if message

  formatdata = {
    sender: sender.id,
    room: room.id,
    event: event.event_id,
    time: Utils.duration_format(milliseconds),
    msg: message
  }

  from_id = ActiveMatrix::MXID.new(sender.id)

  eventdata = {
    format: 'org.matrix.custom.html',
    formatted_body: format(html, formatdata),
    'm.relates_to': {
      event_id: formatdata[:event],
      from: from_id.homeserver,
      ms: milliseconds,
      rel_type: 'xyz.maubot.pong'
    },
    pong: {
      from: from_id.homeserver,
      ms: milliseconds,
      ping: formatdata[:event]
    }
  }

  room.send_custom_message(format(plaintext, formatdata), eventdata, msgtype: 'm.notice')
end

module Utils
  MS_PER_DAY = 86_400_000.0
  MS_PER_HOUR = 3_600_000.0
  MS_PER_MINUTE = 60_000.0
  MS_PER_SECOND = 1_000.0

  def self.duration_format(duration_ms)
    return "#{duration_ms} ms" if duration_ms <= 9000

    timestr = []
    if duration_ms > MS_PER_DAY * 1.1
      duration_ms -= (days = (duration_ms / MS_PER_DAY).floor) * MS_PER_DAY
      timestr << "#{days} days#{'s' if days > 1}" if days.positive?
    end

    if duration_ms > MS_PER_HOUR * 1.1
      duration_ms -= (hours = (duration_ms / MS_PER_HOUR).floor) * MS_PER_HOUR
      timestr << "#{hours} hour#{'s' if hours > 1}" if hours.positive?
    end

    if duration_ms > MS_PER_MINUTE * 1.1
      duration_ms -= (minutes = (duration_ms / MS_PER_MINUTE).floor) * MS_PER_MINUTE
      timestr << "#{minutes} minute#{'s' if minutes > 1}" if minutes.positive?
    end

    seconds = (duration_ms / MS_PER_SECOND).round(timestr.empty? ? 1 : 0)
    seconds = seconds.round if seconds.round == seconds
    timestr << "#{seconds} second#{'s' if seconds > 1}" if seconds.positive?

    if timestr.count > 2
      last = timestr.pop
      [timestr.join(', '), last].join(' and ')
    else
      timestr.join ' and '
    end
  end
end
