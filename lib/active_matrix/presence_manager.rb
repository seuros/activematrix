# frozen_string_literal: true

require 'concurrent'

module ActiveMatrix
  # Manages Matrix presence for agents
  # Provides automatic presence updates, wake hour awareness, and graceful shutdown
  #
  # @example Basic usage
  #   presence = ActiveMatrix::PresenceManager.new(api: api, user_id: '@bot:example.com')
  #   presence.start
  #   presence.set_online(status_msg: 'Ready to help')
  #   # ... later
  #   presence.stop
  #
  # @example With wake hours
  #   presence = ActiveMatrix::PresenceManager.new(
  #     api: api,
  #     user_id: '@bot:example.com',
  #     wake_hour: 6,
  #     sleep_hour: 22
  #   )
  #   presence.start # Will auto-set unavailable outside 6:00-22:00
  #
  class PresenceManager
    include Instrumentation

    attr_reader :user_id, :current_status, :current_message

    # @param api [ActiveMatrix::Api] Matrix API instance
    # @param user_id [String] The user ID to manage presence for
    # @param refresh_interval [Integer] Seconds between presence refreshes (default: 300)
    # @param wake_hour [Integer, nil] Hour (0-23) when bot becomes available (optional)
    # @param sleep_hour [Integer, nil] Hour (0-23) when bot becomes unavailable (optional)
    # @param timezone [String] Timezone for wake/sleep hours (default: system timezone)
    def initialize(api:, user_id:, refresh_interval: 300, wake_hour: nil, sleep_hour: nil, timezone: nil)
      @api = api
      @user_id = user_id
      @refresh_interval = refresh_interval
      @wake_hour = wake_hour
      @sleep_hour = sleep_hour
      @timezone = timezone

      @current_status = 'offline'
      @current_message = nil
      @running = Concurrent::AtomicBoolean.new(false)
      @task = nil
      @mutex = Mutex.new
    end

    # Start the presence manager
    # Begins periodic presence updates
    def start
      return if @running.true?

      @running.make_true
      schedule_refresh
      ActiveMatrix.logger.info("PresenceManager started for #{@user_id}")
    end

    # Stop the presence manager
    # Sets presence to offline and stops refresh loop
    def stop
      return unless @running.true?

      @running.make_false
      @task&.cancel
      @task = nil

      # Set offline on shutdown
      set_offline
      ActiveMatrix.logger.info("PresenceManager stopped for #{@user_id}")
    end

    # Set presence to online
    #
    # @param status_msg [String, nil] Optional status message
    def set_online(status_msg: nil)
      set_presence('online', status_msg)
    end

    # Set presence to unavailable
    #
    # @param status_msg [String, nil] Optional status message
    def set_unavailable(status_msg: nil)
      set_presence('unavailable', status_msg)
    end

    # Set presence to offline
    def set_offline
      set_presence('offline', nil)
    end

    # Check if currently within wake hours
    #
    # @return [Boolean] true if within wake hours or no wake hours configured
    def within_wake_hours?
      return true if @wake_hour.nil? || @sleep_hour.nil?

      current_hour = current_time.hour

      if @wake_hour < @sleep_hour
        # Normal case: wake 6, sleep 22 -> active from 6:00 to 21:59
        current_hour >= @wake_hour && current_hour < @sleep_hour
      else
        # Overnight case: wake 22, sleep 6 -> active from 22:00 to 5:59
        current_hour >= @wake_hour || current_hour < @sleep_hour
      end
    end

    # Get current presence status from server
    #
    # @return [Hash] Presence status including :presence and :status_msg
    def get_status
      instrument_operation(:get_presence, user_id: @user_id) do
        @api.get_presence_status(@user_id)
      end
    rescue StandardError => e
      ActiveMatrix.logger.warn("Failed to get presence for #{@user_id}: #{e.message}")
      { presence: @current_status, status_msg: @current_message }
    end

    private

    def agent_id
      @user_id
    end

    def set_presence(status, message)
      @mutex.synchronize do
        # Check wake hours before setting online
        actual_status = if status == 'online' && !within_wake_hours?
                          'unavailable'
                        else
                          status
                        end

        instrument_operation(:set_presence, user_id: @user_id, status: actual_status) do
          @api.set_presence_status(@user_id, actual_status, message: message)
        end

        @current_status = actual_status
        @current_message = message

        ActiveMatrix.logger.debug("Presence set to #{actual_status} for #{@user_id}")
      end
    rescue StandardError => e
      ActiveMatrix.logger.error("Failed to set presence for #{@user_id}: #{e.message}")
    end

    def schedule_refresh
      return unless @running.true?

      @task = Concurrent::ScheduledTask.execute(@refresh_interval) do
        refresh_presence
        schedule_refresh
      end
    end

    def refresh_presence
      return unless @running.true?

      # Re-check wake hours and update if needed
      if within_wake_hours?
        set_presence(@current_status == 'offline' ? 'online' : @current_status, @current_message)
      else
        set_presence('unavailable', @current_message)
      end
    rescue StandardError => e
      ActiveMatrix.logger.error("Error refreshing presence: #{e.message}")
    end

    def current_time
      if @timezone && defined?(ActiveSupport::TimeZone)
        ActiveSupport::TimeZone[@timezone]&.now || Time.current
      else
        Time.current
      end
    end
  end
end
