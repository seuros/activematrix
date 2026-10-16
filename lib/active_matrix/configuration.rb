# frozen_string_literal: true

module ActiveMatrix
  # Rails-side settings. The daemon has its own (config/activematrixd.toml).
  class Configuration
    # How long handled inbox events and sent outbox commands are kept. The
    # inbox doubles as message history, so this is also how far back a bot
    # can look.
    attr_accessor :inbox_retention, :outbox_retention

    def initialize
      @inbox_retention = 30 * 86_400
      @outbox_retention = 7 * 86_400
    end
  end
end
