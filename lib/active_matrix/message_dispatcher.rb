# frozen_string_literal: true

module ActiveMatrix
  # Dispatches Matrix messages with retry logic and typing indicators
  #
  # @example Basic usage
  #   dispatcher = ActiveMatrix::MessageDispatcher.new(api: api, room_id: '!abc:matrix.org')
  #   dispatcher.send_text('Hello!')
  #
  # @example With typing indicator
  #   dispatcher.send_text('Thinking...', typing_delay: 2.0)
  #
  # @example Thread reply
  #   dispatcher.send_text('Reply', thread_id: '$event_id')
  #
  class MessageDispatcher
    include Instrumentation

    # Default configuration
    DEFAULT_RETRY_COUNT = 3
    DEFAULT_BASE_DELAY = 1.0
    DEFAULT_TYPING_DELAY = 0.5
    DEFAULT_TYPING_TIMEOUT = 30

    attr_reader :api, :room_id, :user_id

    # @param api [ActiveMatrix::Api] Matrix API instance
    # @param room_id [String] Room ID to send messages to
    # @param user_id [String] User ID for typing indicator
    # @param retry_count [Integer] Number of retries on failure
    # @param base_delay [Float] Base delay in seconds for exponential backoff
    # @param typing_delay [Float] Default typing delay in seconds
    def initialize(api:, room_id:, user_id:, retry_count: DEFAULT_RETRY_COUNT,
                   base_delay: DEFAULT_BASE_DELAY, typing_delay: DEFAULT_TYPING_DELAY)
      @api = api
      @room_id = room_id
      @user_id = user_id
      @retry_count = retry_count
      @base_delay = base_delay
      @default_typing_delay = typing_delay
    end

    # Send a plain text message
    #
    # @param text [String] Message text
    # @param msgtype [String] Message type (default: 'm.text')
    # @param typing_delay [Float, nil] Seconds to show typing indicator (nil to skip)
    # @param thread_id [String, nil] Event ID to reply in thread
    # @return [Hash] Response with :event_id
    def send_text(text, msgtype: 'm.text', typing_delay: nil, thread_id: nil)
      content = {
        msgtype: msgtype,
        body: text
      }

      send_with_typing(content, typing_delay: typing_delay, thread_id: thread_id)
    end

    # Send an HTML message
    #
    # @param html [String] HTML content
    # @param body [String, nil] Plain text fallback (auto-generated if nil)
    # @param msgtype [String] Message type (default: 'm.text')
    # @param typing_delay [Float, nil] Seconds to show typing indicator
    # @param thread_id [String, nil] Event ID to reply in thread
    # @return [Hash] Response with :event_id
    def send_html(html, body: nil, msgtype: 'm.text', typing_delay: nil, thread_id: nil)
      plain_body = body || strip_html(html)

      content = {
        msgtype: msgtype,
        body: plain_body,
        format: 'org.matrix.custom.html',
        formatted_body: html
      }

      send_with_typing(content, typing_delay: typing_delay, thread_id: thread_id)
    end

    # Send a notice message (typically for bot responses)
    #
    # @param text [String] Notice text
    # @param typing_delay [Float, nil] Seconds to show typing indicator
    # @param thread_id [String, nil] Event ID to reply in thread
    # @return [Hash] Response with :event_id
    def send_notice(text, typing_delay: nil, thread_id: nil)
      send_text(text, msgtype: 'm.notice', typing_delay: typing_delay, thread_id: thread_id)
    end

    # Send an HTML notice message
    #
    # @param html [String] HTML content
    # @param body [String, nil] Plain text fallback
    # @param typing_delay [Float, nil] Seconds to show typing indicator
    # @param thread_id [String, nil] Event ID to reply in thread
    # @return [Hash] Response with :event_id
    def send_html_notice(html, body: nil, typing_delay: nil, thread_id: nil)
      send_html(html, body: body, msgtype: 'm.notice', typing_delay: typing_delay, thread_id: thread_id)
    end

    # Send an emote message (/me action)
    #
    # @param text [String] Emote text
    # @param typing_delay [Float, nil] Seconds to show typing indicator
    # @param thread_id [String, nil] Event ID to reply in thread
    # @return [Hash] Response with :event_id
    def send_emote(text, typing_delay: nil, thread_id: nil)
      send_text(text, msgtype: 'm.emote', typing_delay: typing_delay, thread_id: thread_id)
    end

    # Show typing indicator
    #
    # @param typing [Boolean] Whether to show or hide typing
    # @param timeout [Integer] Timeout in seconds
    def set_typing(typing: true, timeout: DEFAULT_TYPING_TIMEOUT)
      @api.set_typing(@room_id, @user_id, typing: typing, timeout: timeout)
    rescue StandardError => e
      ActiveMatrix.logger.debug("Failed to set typing indicator: #{e.message}")
    end

    private

    def agent_id
      @user_id
    end

    def send_with_typing(content, typing_delay:, thread_id:)
      effective_delay = typing_delay || @default_typing_delay

      # Show typing indicator
      if effective_delay.positive?
        set_typing(typing: true)
        sleep(effective_delay)
        set_typing(typing: false)
      end

      # Add thread relation if specified
      if thread_id
        content[:'m.relates_to'] = {
          rel_type: 'm.thread',
          event_id: thread_id
        }
      end

      send_with_retry(content)
    end

    def send_with_retry(content)
      attempts = 0

      instrument_operation(:send_message, room_id: @room_id) do
        begin
          @api.send_message_event(@room_id, 'm.room.message', content)
        rescue ActiveMatrix::MatrixRequestError => e
          attempts += 1

          if attempts <= @retry_count && retryable_error?(e)
            delay = calculate_backoff(attempts)
            ActiveMatrix.logger.warn("Message send failed (attempt #{attempts}/#{@retry_count}), retrying in #{delay}s: #{e.message}")
            sleep(delay)
            retry
          end

          raise
        end
      end
    end

    def retryable_error?(error)
      # Retry on rate limiting, server errors, or network issues
      case error
      when ActiveMatrix::MatrixTooManyRequestsError
        true
      when ActiveMatrix::MatrixRequestError
        error.httpstatus.to_i >= 500
      else
        false
      end
    end

    def calculate_backoff(attempt)
      # Exponential backoff with full jitter
      max_delay = @base_delay * (2**(attempt - 1))
      rand * max_delay
    end

    def strip_html(html)
      # Simple HTML stripping - remove tags and decode entities
      text = html.gsub(/<br\s*\/?>/i, "\n")
      text = text.gsub(/<\/?[^>]+>/, '')
      text = text.gsub(/&nbsp;/, ' ')
      text = text.gsub(/&lt;/, '<')
      text = text.gsub(/&gt;/, '>')
      text = text.gsub(/&amp;/, '&')
      text = text.gsub(/&quot;/, '"')
      text.strip
    end
  end
end
