# frozen_string_literal: true

module ActiveMatrix
  module Bot
    # Built-in commands that can be included in bot classes
    #
    # @example Include in a bot
    #   class MyBot < ActiveMatrix::Bot::Base
    #     include ActiveMatrix::Bot::BuiltinCommands
    #   end
    #
    module BuiltinCommands
      def self.included(base)
        base.extend(ClassMethods)
        base.register_builtin_commands
      end

      module ClassMethods
        def register_builtin_commands
          # Ping command - connectivity test
          command(
            :ping,
            desc: 'Test bot connectivity and response time'
          ) do
            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            response_parts = [
              '**Pong!**',
              '',
              'Bot is online and responding',
              "Server time: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
            ]

            end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            response_time_ms = ((end_time - start_time) * 1000).round(2)
            response_parts.insert(2, "Response time: #{response_time_ms}ms")

            room.send_notice(response_parts.join("\n"))
          end

          # Version command - show bot version
          command(
            :version,
            desc: 'Show bot version information'
          ) do
            response_parts = [
              '**Version Information**',
              '',
              "ActiveMatrix: #{ActiveMatrix::VERSION}",
              "Ruby: #{RUBY_VERSION}",
              "Platform: #{RUBY_PLATFORM}"
            ]

            # Add application version if available
            if defined?(Rails) && Rails.application.respond_to?(:version)
              response_parts << "Application: #{Rails.application.version}"
            end

            room.send_notice(response_parts.join("\n"))
          end

          # Status command - show bot status
          command(
            :status,
            desc: 'Show bot status and health information'
          ) do
            response_parts = [
              '**Bot Status**',
              '',
              "State: Online",
              "Uptime: #{format_uptime}",
              "User ID: #{client.mxid}",
              "Homeserver: #{client.api.homeserver}"
            ]

            # Add room count if available
            if client.respond_to?(:rooms)
              room_count = client.rooms.size
              response_parts << "Joined rooms: #{room_count}"
            end

            # Add metrics if available
            if defined?(ActiveMatrix::Metrics)
              metrics = ActiveMatrix::Metrics.instance.get_health_summary
              if metrics[:total_operations].positive?
                response_parts += [
                  '',
                  '**Metrics**',
                  "Total operations: #{metrics[:total_operations]}",
                  "Success rate: #{metrics[:overall_success_rate]}%"
                ]
              end
            end

            room.send_notice(response_parts.join("\n"))
          end

          # Time command - show current time
          command(
            :time,
            desc: 'Show current time in specified timezone',
            notes: 'Usage: !time [TIMEZONE]. Examples: !time UTC, !time America/New_York'
          ) do |timezone = nil|
            time = if timezone && defined?(ActiveSupport::TimeZone)
                     tz = ActiveSupport::TimeZone[timezone]
                     if tz
                       tz.now
                     else
                       room.send_notice("Unknown timezone: #{timezone}. Using server time.")
                       Time.current
                     end
                   else
                     Time.current
                   end

            formatted = time.strftime('%Y-%m-%d %H:%M:%S %Z')
            unix_timestamp = time.to_i

            response_parts = [
              "**Current Time**",
              '',
              formatted,
              "Unix timestamp: #{unix_timestamp}"
            ]

            room.send_notice(response_parts.join("\n"))
          end

          # Echo command - echo back message
          command(
            :echo,
            desc: 'Echo back the provided message'
          ) do |message = nil|
            if message.nil? || message.strip.empty?
              room.send_notice('Nothing to echo. Usage: !echo <message>')
            else
              room.send_text(message)
            end
          end

          # Rooms command - list joined rooms (admin only)
          command(
            :rooms,
            desc: 'List joined rooms',
            only: :admin
          ) do
            rooms_list = client.rooms.map do |r|
              name = r.display_name || r.id
              "- #{name}"
            end

            if rooms_list.empty?
              room.send_notice('Not joined to any rooms.')
            else
              response = [
                "**Joined Rooms** (#{rooms_list.size})",
                '',
                *rooms_list.first(20)
              ]

              response << "... and #{rooms_list.size - 20} more" if rooms_list.size > 20

              room.send_notice(response.join("\n"))
            end
          end
        end
      end

      private

      def format_uptime
        return 'Unknown' unless defined?(@start_time)

        seconds = (Time.current - @start_time).to_i
        days = seconds / 86_400
        hours = (seconds % 86_400) / 3600
        minutes = (seconds % 3600) / 60
        secs = seconds % 60

        parts = []
        parts << "#{days}d" if days.positive?
        parts << "#{hours}h" if hours.positive?
        parts << "#{minutes}m" if minutes.positive?
        parts << "#{secs}s" if secs.positive? || parts.empty?

        parts.join(' ')
      end
    end
  end
end
