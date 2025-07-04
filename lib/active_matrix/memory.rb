# frozen_string_literal: true

module ActiveMatrix
  # Memory system for multi-agent architecture
  module Memory
    autoload :AgentMemory, 'active_matrix/memory/agent_memory'
    autoload :ConversationMemory, 'active_matrix/memory/conversation_memory'
    autoload :GlobalMemory, 'active_matrix/memory/global_memory'
    autoload :Base, 'active_matrix/memory/base'

    class << self
      # Get memory interface for an agent
      def for_agent(agent)
        AgentMemory.new(agent)
      end

      # Get conversation memory for agent and user
      def for_conversation(agent, user_id, room_id)
        ConversationMemory.new(agent, user_id, room_id)
      end

      # Access global memory
      def global
        GlobalMemory.instance
      end
    end
  end
end
