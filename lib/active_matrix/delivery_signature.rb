# frozen_string_literal: true

require 'openssl'

module ActiveMatrix
  # Verifies the daemon's delivery requests: HMAC-SHA256 over
  # "#{timestamp}.#{body}", sent as X-ActiveMatrix-Timestamp and
  # X-ActiveMatrix-Signature: sha256=<hex>. Requests older than the window
  # are refused, so a captured one cannot be replayed later.
  module DeliverySignature
    WINDOW = 300

    module_function

    def sign(secret, timestamp, body)
      "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")}"
    end

    def valid?(secret:, timestamp:, signature:, body:, now: Time.now.to_i)
      return false if secret.blank? || signature.blank? || !timestamp.to_s.match?(/\A\d+\z/)
      return false if (now - timestamp.to_i).abs > WINDOW

      ActiveSupport::SecurityUtils.secure_compare(sign(secret, timestamp, body), signature)
    end
  end
end
