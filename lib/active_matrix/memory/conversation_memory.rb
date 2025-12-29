# frozen_string_literal: true

module ActiveMatrix
  module Memory
    # Per-conversation memory storage (speaker-specific)
    class ConversationMemory < Base
      attr_reader :agent, :user_id, :room_id

      def initialize(agent, user_id, room_id)
        super()
        @agent = agent
        @user_id = user_id
        @room_id = room_id
      end

      # Get conversation context
      def context
        fetch_with_cache('context', expires_in: 1.hour) do
          record = find_or_create_record
          record.context
        end
      end

      # Update conversation context
      def update_context(data)
        record = find_or_create_record
        record.context = record.context.merge(data)
        record.save!

        # Update cache
        invalidate_cache
        true
      end

      # Add a message to history
      def add_message(event)
        record = find_or_create_record
        record.add_message({
                             event_id: event[:event_id],
                             sender: event[:sender],
                             content: event.dig(:content, :body),
                             timestamp: event[:origin_server_ts] || (Time.current.to_i * 1000)
                           })

        # Update agent activity
        @agent.update_activity!
        @agent.increment_messages_handled!

        # Invalidate cache
        invalidate_cache
        true
      end

      # Get recent messages
      def recent_messages(limit = 10)
        fetch_with_cache('recent_messages', expires_in: 5.minutes) do
          record = find_or_create_record
          record.recent_messages(limit)
        end
      end

      # Get last message timestamp
      def last_message_at
        record = conversation_record
        record&.last_message_at
      end

      # Check if conversation is active (recent activity)
      def active?
        last_at = last_message_at
        last_at.present? && last_at > 1.hour.ago
      end

      # Clear conversation history but keep context
      def clear_history!
        record = conversation_record
        return false unless record

        record.prune_history!
        invalidate_cache
        true
      end

      # Get or set a specific context value
      def [](key)
        context[key.to_s]
      end

      def []=(key, value)
        update_context(key.to_s => value)
      end

      # Remember something in conversation context
      def remember(key)
        value = self[key]
        return value if value.present?

        value = yield
        self[key] = value if value.present?
        value
      end

      # Get conversation summary
      def summary
        {
          user_id: @user_id,
          room_id: @room_id,
          active: active?,
          message_count: conversation_record&.message_count || 0,
          last_message_at: last_message_at,
          context: context
        }
      end

      protected

      def cache_key(suffix)
        "conversation/#{@agent.id}/#{@user_id}/#{@room_id}/#{suffix}"
      end

      def conversation_record
        ActiveMatrix::ChatSession.find_by(
          agent: @agent,
          user_id: @user_id,
          room_id: @room_id
        )
      end

      def find_or_create_record
        ActiveMatrix::ChatSession.find_or_create_by!(
          agent: @agent,
          user_id: @user_id,
          room_id: @room_id
        )
      end

      def invalidate_cache
        return unless @cache_enabled

        Rails.cache.delete(cache_key('context'))
        Rails.cache.delete(cache_key('recent_messages'))
      end
    end
  end
end
