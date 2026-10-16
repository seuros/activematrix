# frozen_string_literal: true

module ActiveMatrix
  # Where activematrixd pushes `(agent, room)` pairs. Verifies the signature
  # and enqueues one DrainRoomJob per room; the events themselves are read
  # from the inbox.
  class DeliveriesController < ActionController::API
    def create
      secret = ActiveMatrix.config.delivery_secret
      return head(:service_unavailable) if secret.blank?

      body = request.raw_post
      signed = DeliverySignature.valid?(secret:, body:, timestamp: request.headers['X-ActiveMatrix-Timestamp'],
                                        signature: request.headers['X-ActiveMatrix-Signature'])
      return head(:unauthorized) unless signed

      rooms = JSON.parse(body).fetch('rooms')
      rooms.each { DrainRoomJob.perform_later(it.fetch('agent_id'), it.fetch('room_id')) }
      head :accepted
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError
      head :bad_request
    end
  end
end
