# frozen_string_literal: true

module ActiveMatrix
  # Something Rails wants sent to Matrix. The daemon claims pending rows and
  # executes them; the row id is the Matrix transaction id, so a retried send
  # never posts twice.
  #
  # Create these inside the transaction that decided to send them: if it rolls
  # back, nothing is sent. The NOTIFY that wakes the daemon is part of that
  # transaction too, so it fires on commit and never for a rollback.
  class OutboxCommand < ApplicationRecord
    self.table_name = 'active_matrix_outbox'

    KINDS = %w[
      send state redact join leave invite kick ban unban
      create_room typing receipt profile upload
    ].freeze
    STATUSES = %w[pending sending sent failed].freeze
    ROOMLESS_KINDS = %w[create_room profile upload].freeze
    NOTIFY_CHANNEL = 'active_matrix_outbox'
    DONE_CHANNEL = 'active_matrix_outbox_done'

    class WaitInTransaction < StandardError; end
    class Timeout < StandardError; end

    belongs_to :agent, class_name: 'ActiveMatrix::Agent', inverse_of: :outbox_commands

    enum :status, STATUSES.index_by(&:itself), validate: true

    # Written by the daemon once it has claimed the row.
    attr_readonly :attempts, :result, :last_error, :sent_at

    validates :kind, inclusion: { in: KINDS }
    validates :room_id, presence: true, unless: -> { ROOMLESS_KINDS.include?(kind) }
    validate :payload_is_an_object

    after_create :notify_daemon

    def finished? = sent? || failed?

    # Blocks until the daemon has sent or given up on this command, then
    # returns it reloaded. Only outside a transaction: inside one the row is
    # not committed, so the daemon cannot see it yet.
    def wait(timeout: 10)
      self.class.connection_pool.with_connection do |connection|
        raise WaitInTransaction, 'commit the transaction that created the command before waiting' \
          if connection.transaction_open?

        await_done(connection.raw_connection, Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
      end
    end

    private

    def payload_is_an_object
      errors.add(:payload, 'must be a JSON object') unless payload.is_a?(Hash)
    end

    def notify_daemon
      self.class.connection.execute("NOTIFY #{NOTIFY_CHANNEL}, #{self.class.connection.quote(id)}")
    end

    # LISTEN first, then check: a notification sent between the check and the
    # LISTEN would otherwise be missed.
    def await_done(raw, deadline)
      raw.exec("LISTEN #{DONE_CHANNEL}")
      loop do
        reload
        return self if finished?

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout, "outbox command #{id} still #{status} after waiting" if remaining <= 0

        raw.wait_for_notify(remaining)
      end
    ensure
      raw.exec("UNLISTEN #{DONE_CHANNEL}")
    end
  end
end
