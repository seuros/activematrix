# frozen_string_literal: true

module ActiveMatrix
  class ApplicationJob < ActiveJob::Base
    # Jobs enqueued by a bot handler wait for its transaction: a handler
    # that rolls back enqueues nothing.
    self.enqueue_after_transaction_commit = true
  end
end
