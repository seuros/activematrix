# frozen_string_literal: true

module ActiveMatrix
  # Deletes expired memories, handled inbox events and finished outbox
  # commands past their retention. Schedule it as a recurring job (Solid
  # Queue: config/recurring.yml); it deletes in batches so it never holds a
  # long lock.
  class MemoryReaperJob < ApplicationJob
    BATCH_SIZE = 1_000

    def perform
      config = ActiveMatrix.config
      reap(Memory.expired)
      reap(InboxEvent.processed.where(processed_at: ...config.inbox_retention.seconds.ago))
      reap(OutboxCommand.where(status: %w[sent failed]).where(updated_at: ...config.outbox_retention.seconds.ago))
    end

    private

    def reap(scope)
      loop { break if scope.limit(BATCH_SIZE).delete_all < BATCH_SIZE }
    end
  end
end
