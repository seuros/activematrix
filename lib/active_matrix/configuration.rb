# frozen_string_literal: true

module ActiveMatrix
  # Rails-side settings. The daemon has its own (config/activematrixd.toml).
  class Configuration
    # How long handled inbox events and sent outbox commands are kept. The
    # inbox doubles as message history, so this is also how far back a bot
    # can look.
    attr_accessor :inbox_retention, :outbox_retention

    # Verifies the daemon's delivery requests. The same value as the
    # daemon's ACTIVEMATRIX_DELIVERY_SECRET; defaults to that variable.
    attr_writer :delivery_secret

    def initialize
      @inbox_retention = 30 * 86_400
      @outbox_retention = 7 * 86_400
    end

    def delivery_secret = @delivery_secret || ENV.fetch('ACTIVEMATRIX_DELIVERY_SECRET', nil)
  end
end
