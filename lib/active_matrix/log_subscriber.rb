# frozen_string_literal: true

module ActiveMatrix
  # Logs `dispatch.active_matrix` and `command.active_matrix` at debug level.
  class LogSubscriber < ActiveSupport::LogSubscriber
    def dispatch(event)
      payload = event.payload
      debug do
        "  ActiveMatrix #{payload[:agent]} handled #{payload[:event_type]} #{payload[:event_id]} " \
          "(#{event.duration.round(1)}ms)"
      end
    end
    subscribe_log_level :dispatch, :debug

    def command(event)
      payload = event.payload
      debug { "  ActiveMatrix #{payload[:agent]} ran !#{payload[:command]} (#{event.duration.round(1)}ms)" }
    end
    subscribe_log_level :command, :debug
  end
end
