# frozen_string_literal: true

module ActiveMatrix
  # Runs the bot on a room's pending inbox events, oldest first.
  #
  # Each event is handled in its own transaction, which holds a Postgres
  # advisory lock on (agent, room): jobs for one room take turns, so events
  # are handled in order whatever the job backend does, and each exactly
  # once, because `processed_at` commits with the handler's writes.
  #
  # A handler that raises rolls back its writes; the event is retried with
  # backoff and, after MAX_ATTEMPTS, set aside (processed, with last_error)
  # so one bad event cannot block its room forever.
  class DrainRoomJob < ApplicationJob
    MAX_ATTEMPTS = 5

    class HandlerFailed < StandardError; end

    retry_on HandlerFailed, wait: :polynomially_longer, attempts: MAX_ATTEMPTS + 1

    def perform(agent_id, room_id)
      agent = Agent.find_by(id: agent_id)
      return unless agent

      loop { break unless drain_one(agent, room_id) }
    end

    private

    # Handles the oldest pending event; false once there is none.
    def drain_one(agent, room_id)
      event = nil
      InboxEvent.transaction(requires_new: true) do
        lock_room(agent.id, room_id)
        event = InboxEvent.pending.where(agent_id: agent.id, room_id:).in_order.lock.first
        if event
          bot_class(agent).dispatch(agent:, event:)
          event.update!(processed_at: Time.current)
        end
      end
      event.present?
    rescue StandardError => e
      raise unless event

      set_aside = record_failure(event, e)
      raise HandlerFailed, "#{event.event_id}: #{e.class}: #{e.message}" unless set_aside

      true
    end

    def lock_room(agent_id, room_id)
      key = InboxEvent.connection.quote("active_matrix:#{agent_id}:#{room_id}")
      InboxEvent.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{key}, 0))")
    end

    def bot_class(agent)
      klass = agent.bot_class.safe_constantize
      return klass if klass.is_a?(Class) && klass < Bot::Base

      raise NameError, "#{agent.bot_class} is not an ActiveMatrix::Bot::Base"
    end

    # Records the failure; true when the event is set aside for good.
    def record_failure(event, error)
      attempts = event.attempts + 1
      set_aside = attempts >= MAX_ATTEMPTS
      event.update!(attempts:, last_error: "#{error.class}: #{error.message}",
                    processed_at: (Time.current if set_aside))
      Rails.logger.error("[ActiveMatrix] #{event.event_id} failed (#{attempts}/#{MAX_ATTEMPTS}): #{error.message}")
      set_aside
    end
  end
end
