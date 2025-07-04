# frozen_string_literal: true

require 'singleton'
require 'concurrent'

module ActiveMatrix
  # Routes Matrix events to appropriate agents
  class EventRouter
    include Singleton
    include ActiveMatrix::Logging

    def initialize
      @routes = Concurrent::Array.new
      @event_queue = Queue.new
      @processing = false
      @worker_thread = nil
    end

    # Register an event route
    def register_route(agent_id:, room_id: nil, event_type: nil, user_id: nil, priority: 50, &block)
      route = {
        id: SecureRandom.uuid,
        agent_id: agent_id,
        room_id: room_id,
        event_type: event_type,
        user_id: user_id,
        priority: priority,
        handler: block
      }

      @routes << route
      @routes.sort_by! { |r| -r[:priority] } # Higher priority first

      logger.debug "Registered route: #{route.except(:handler).inspect}"
      route[:id]
    end

    # Unregister a route
    def unregister_route(route_id)
      @routes.delete_if { |route| route[:id] == route_id }
    end

    # Clear all routes for an agent
    def clear_agent_routes(agent_id)
      @routes.delete_if { |route| route[:agent_id] == agent_id }
    end

    # Route an event to appropriate agents
    def route_event(event)
      return unless @processing

      # Queue the event for processing
      @event_queue << event
    end

    # Start the event router
    def start
      return if @processing

      @processing = true
      @worker_thread = Thread.new do
        Thread.current.name = 'event-router'
        process_events
      end

      logger.info 'Event router started'
    end

    # Stop the event router
    def stop
      @processing = false
      @worker_thread&.kill
      @event_queue.clear

      logger.info 'Event router stopped'
    end

    # Check if router is running
    def running?
      @processing && @worker_thread&.alive?
    end

    # Get routes for debugging
    def routes_summary
      @routes.map { |r| r.except(:handler) }
    end

    # Broadcast an event to all agents
    def broadcast_event(event)
      AgentRegistry.instance.all_instances.each do |bot|
        bot._handle_event(event) if bot.respond_to?(:_handle_event)
      rescue StandardError => e
        logger.error "Error broadcasting to bot: #{e.message}"
      end
    end

    private

    def process_events
      while @processing
        begin
          # Wait for event with timeout
          event = nil
          Timeout.timeout(1) { event = @event_queue.pop }

          next unless event

          # Find matching routes
          matching_routes = find_matching_routes(event)

          if matching_routes.empty?
            logger.debug "No routes matched for event: #{event[:type]} in #{event[:room_id]}"
            next
          end

          # Process routes in priority order
          matching_routes.each do |route|
            process_route(route, event)
          end
        rescue Timeout::Error
          # Normal timeout, continue loop
        rescue StandardError => e
          logger.error "Event router error: #{e.message}"
          logger.error e.backtrace.join("\n")
        end
      end
    end

    def find_matching_routes(event)
      @routes.select do |route|
        # Check room match
        next false if route[:room_id] && route[:room_id] != event[:room_id]

        # Check event type match
        next false if route[:event_type] && route[:event_type] != event[:type]

        # Check user match
        next false if route[:user_id] && route[:user_id] != event[:sender]

        # Check if agent is running
        registry = AgentRegistry.instance
        agent_entry = registry.get(route[:agent_id])
        next false unless agent_entry

        true
      end
    end

    def process_route(route, event)
      registry = AgentRegistry.instance
      agent_entry = registry.get(route[:agent_id])

      return unless agent_entry

      bot = agent_entry[:instance]

      begin
        if route[:handler]
          # Custom handler
          route[:handler].call(bot, event)
        elsif bot.respond_to?(:_handle_event)
          # Default handling
          bot._handle_event(event)
        end
      rescue StandardError => e
        logger.error "Error processing route for agent #{agent_entry[:record].name}: #{e.message}"
        logger.error e.backtrace.first(5).join("\n")
      end
    end
  end

  # Routing DSL for bots
  module Bot
    class MultiInstanceBase
      # Route events to this bot
      def self.route(event_type: nil, room_id: nil, user_id: nil, priority: 50, &block)
        # Routes will be registered when bot instance is created
        @event_routes ||= []
        @event_routes << {
          event_type: event_type,
          room_id: room_id,
          user_id: user_id,
          priority: priority,
          handler: block
        }
      end

      # Get defined routes
      def self.event_routes
        @event_routes || []
      end

      # Register routes for this instance
      def register_routes
        return unless @agent_record

        router = EventRouter.instance

        self.class.event_routes.each do |route_def|
          router.register_route(
            agent_id: @agent_record.id,
            **route_def
          )
        end
      end

      # Clear routes for this instance
      def clear_routes
        return unless @agent_record

        EventRouter.instance.clear_agent_routes(@agent_record.id)
      end
    end
  end
end
