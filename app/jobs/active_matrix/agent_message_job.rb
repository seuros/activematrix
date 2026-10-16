# frozen_string_literal: true

module ActiveMatrix
  # Delivers an agent message to its recipient's bot, in a transaction with
  # marking it processed.
  class AgentMessageJob < ApplicationJob
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(message_id)
      message = AgentMessage.pending.find_by(id: message_id)
      return unless message

      AgentMessage.transaction do
        agent = message.to_agent
        agent.bot_class.constantize.receive(agent:, message:)
        message.update!(processed_at: Time.current)
      end
    end
  end
end
