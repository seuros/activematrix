# frozen_string_literal: true

require 'concurrent'
require 'singleton'

module ActiveMatrix
  # Metrics collection for Matrix agent operations
  # Provides structured metrics that can be exported to monitoring systems
  #
  # @example Getting agent metrics
  #   metrics = ActiveMatrix::Metrics.instance.get_agent_metrics('agent_123')
  #   puts metrics[:overall_success_rate]
  #
  # @example Getting health summary
  #   summary = ActiveMatrix::Metrics.instance.get_health_summary
  #   puts "Healthy agents: #{summary[:healthy_agents]}"
  #
  class Metrics
    include Singleton

    def initialize
      @metrics = Concurrent::Hash.new
      @component_metrics = Concurrent::Hash.new
      setup_notification_subscribers
    end

    # Record operation metrics
    #
    # @param operation [Symbol, String] Operation name
    # @param component [String] Component name (e.g., 'MessageDispatcher')
    # @param agent_id [String] Agent identifier
    # @param status [String] 'success' or 'error'
    # @param duration_ms [Float] Operation duration in milliseconds
    # @param error_class [String, nil] Error class name if status is 'error'
    # @param metadata [Hash] Additional metadata (user_id, room_id, etc.)
    def record_operation(operation, component:, agent_id:, status:, duration_ms:, error_class: nil, **metadata)
      component_key = "#{agent_id}:#{component}"
      operation_key = "#{component_key}:#{operation}"

      # Initialize metrics if needed
      @component_metrics[component_key] ||= initialize_component_metrics(component, agent_id)
      @metrics[operation_key] ||= initialize_operation_metrics(operation, component, agent_id)

      # Update component-level metrics
      update_component_metrics(@component_metrics[component_key], status, duration_ms)

      # Update operation-level metrics
      metric = @metrics[operation_key]
      metric[:total_count].increment
      metric[:last_operation_at] = Time.current

      # Always update duration stats regardless of status
      update_duration_stats(metric[:duration_stats], duration_ms)

      case status
      when 'success'
        metric[:success_count].increment
      when 'error'
        metric[:error_count].increment
        metric[:last_error_at] = Time.current

        error_type = error_class || metadata[:error_type] || 'unknown'
        metric[:error_breakdown][error_type] ||= Concurrent::AtomicFixnum.new(0)
        metric[:error_breakdown][error_type].increment
      end

      # Track recent operations (sliding window) with thread-safe array
      metric[:recent_operations] << {
        timestamp: Time.current,
        status: status,
        duration_ms: duration_ms,
        metadata: metadata.merge(error_class: error_class).slice(:error_type, :error_class, :user_id, :room_id)
      }

      # Keep only last 100 operations
      metric[:recent_operations].shift if metric[:recent_operations].size > 100
    end

    # Get metrics for a specific agent instance
    #
    # @param agent_id [String] Agent identifier
    # @return [Hash] Agent metrics including components, success rates, and health status
    def get_agent_metrics(agent_id)
      agent_metrics = @metrics.select { |key, _| key.start_with?("#{agent_id}:") }

      return {} if agent_metrics.empty?

      components = {}
      total_operations = 0
      total_successes = 0
      total_errors = 0

      agent_metrics.each do |key, metrics|
        parts = key.split(':', 3)
        component = parts[1]
        operation = parts[2]

        components[component] ||= {
          operations: {},
          total_count: 0,
          success_count: 0,
          error_count: 0
        }

        total_count = metrics[:total_count].value
        success_count = metrics[:success_count].value
        error_count = metrics[:error_count].value

        components[component][:total_count] += total_count
        components[component][:success_count] += success_count
        components[component][:error_count] += error_count

        total_operations += total_count
        total_successes += success_count
        total_errors += error_count

        components[component][:operations][operation] = {
          total_count: total_count,
          success_count: success_count,
          error_count: error_count,
          success_rate: calculate_success_rate(metrics),
          avg_duration_ms: metrics[:duration_stats][:avg].value,
          p95_duration_ms: metrics[:duration_stats][:p95].value,
          last_operation_at: metrics[:last_operation_at],
          last_error_at: metrics[:last_error_at],
          error_breakdown: serialize_error_breakdown(metrics[:error_breakdown])
        }
      end

      {
        agent_id: agent_id,
        total_operations: total_operations,
        total_successes: total_successes,
        total_errors: total_errors,
        overall_success_rate: total_operations.positive? ? (total_successes.to_f / total_operations * 100).round(2) : 0,
        components: components,
        health_status: calculate_agent_health(total_operations, total_successes)
      }
    end

    # Get metrics for a specific component
    #
    # @param agent_id [String] Agent identifier
    # @param component [String] Component name
    # @return [Hash] Component metrics
    def get_component_metrics(agent_id, component)
      component_key = "#{agent_id}:#{component}"
      component_metrics = @component_metrics[component_key]

      return default_component_metrics if component_metrics.nil?

      operations = @metrics.select { |key, _| key.start_with?("#{component_key}:") }

      {
        component: component,
        agent_id: agent_id,
        total_operations: component_metrics[:total_count].value,
        success_count: component_metrics[:success_count].value,
        error_count: component_metrics[:error_count].value,
        success_rate: calculate_success_rate(component_metrics),
        avg_duration_ms: component_metrics[:duration_stats][:avg].value,
        p95_duration_ms: component_metrics[:duration_stats][:p95].value,
        operations: operations.transform_keys { |k| k.split(':', 3).last }
                              .transform_values { |v| operation_summary(v) }
      }
    end

    # Get top operations by volume
    #
    # @param agent_id [String] Agent identifier
    # @param limit [Integer] Maximum number of operations to return
    # @return [Array<Hash>] Top operations sorted by count
    def top_operations_by_volume(agent_id, limit: 10)
      agent_metrics = @metrics.select { |key, _| key.start_with?("#{agent_id}:") }

      operations = agent_metrics.map do |key, metrics|
        parts = key.split(':', 3)
        {
          component: parts[1],
          operation: parts[2],
          count: metrics[:total_count].value,
          success_rate: calculate_success_rate(metrics),
          avg_duration_ms: metrics[:duration_stats][:avg].value
        }
      end

      operations.sort_by { |op| -op[:count] }.first(limit)
    end

    # Get recent errors
    #
    # @param agent_id [String] Agent identifier
    # @param limit [Integer] Maximum number of errors to return
    # @return [Array<Hash>] Recent errors sorted by timestamp (newest first)
    def recent_errors(agent_id, limit: 20)
      agent_metrics = @metrics.select { |key, _| key.start_with?("#{agent_id}:") }
      errors = []

      agent_metrics.each do |key, metrics|
        parts = key.split(':', 3)
        component = parts[1]
        operation = parts[2]

        metrics[:recent_operations].to_a.select { |op| op[:status] == 'error' }.each do |error_op|
          errors << {
            timestamp: error_op[:timestamp],
            component: component,
            operation: operation,
            duration_ms: error_op[:duration_ms],
            metadata: error_op[:metadata]
          }
        end
      end

      errors.sort_by { |e| -e[:timestamp].to_f }.first(limit)
    end

    # Get health summary for all agents
    #
    # @return [Hash] Summary of agent health across the system
    def get_health_summary
      agent_ids = @metrics.keys.map { |key| key.split(':', 2).first }.uniq

      agents = agent_ids.map { |agent_id| get_agent_metrics(agent_id) }

      {
        total_agents: agents.length,
        healthy_agents: agents.count { |a| a[:health_status] == :healthy },
        degraded_agents: agents.count { |a| a[:health_status] == :degraded },
        unhealthy_agents: agents.count { |a| a[:health_status] == :unhealthy },
        total_operations: agents.sum { |a| a[:total_operations] },
        overall_success_rate: calculate_overall_success_rate(agents),
        agents: agents.map do |agent|
          {
            agent_id: agent[:agent_id],
            health_status: agent[:health_status],
            success_rate: agent[:overall_success_rate],
            total_operations: agent[:total_operations]
          }
        end
      }
    end

    # Reset all metrics (useful for testing)
    def reset!
      @metrics.clear
      @component_metrics.clear
    end

    # Reset metrics for specific agent
    #
    # @param agent_id [String] Agent identifier
    def reset_agent!(agent_id)
      @metrics.delete_if { |key, _| key.start_with?("#{agent_id}:") }
      @component_metrics.delete_if { |key, _| key.start_with?("#{agent_id}:") }
      ActiveMatrix.logger.info("Reset metrics for Matrix agent: #{agent_id}")
    end

    private

    def setup_notification_subscribers
      # Subscribe to ActiveMatrix events
      ActiveSupport::Notifications.subscribe(/^activematrix\./) do |name, start, finish, _id, payload|
        operation = name.sub('activematrix.', '')
        duration_ms = ((finish - start) * 1000).round(2)

        record_operation(
          operation,
          component: payload[:component] || 'Unknown',
          agent_id: payload[:agent_id] || 'unknown',
          status: payload[:status],
          duration_ms: duration_ms,
          error_type: payload[:error_category],
          error_class: payload[:error_class],
          user_id: payload[:user_id],
          room_id: payload[:room_id]
        )
      end
    end

    def initialize_component_metrics(component, agent_id)
      {
        component: component,
        agent_id: agent_id,
        total_count: Concurrent::AtomicFixnum.new(0),
        success_count: Concurrent::AtomicFixnum.new(0),
        error_count: Concurrent::AtomicFixnum.new(0),
        duration_stats: initialize_duration_stats,
        created_at: Time.current
      }
    end

    def initialize_operation_metrics(operation, component, agent_id)
      {
        operation: operation,
        component: component,
        agent_id: agent_id,
        total_count: Concurrent::AtomicFixnum.new(0),
        success_count: Concurrent::AtomicFixnum.new(0),
        error_count: Concurrent::AtomicFixnum.new(0),
        duration_stats: initialize_duration_stats,
        error_breakdown: Concurrent::Hash.new,
        recent_operations: Concurrent::Array.new,
        created_at: Time.current,
        last_operation_at: nil,
        last_error_at: nil
      }
    end

    def initialize_duration_stats
      Concurrent::Hash.new.tap do |stats|
        stats[:total] = Concurrent::AtomicFixnum.new(0)
        stats[:count] = Concurrent::AtomicFixnum.new(0)
        stats[:avg] = Concurrent::AtomicReference.new(0)
        stats[:min] = Concurrent::AtomicReference.new(Float::INFINITY)
        stats[:max] = Concurrent::AtomicReference.new(0)
        stats[:p95] = Concurrent::AtomicReference.new(0)
        stats[:values] = Concurrent::Array.new
      end
    end

    def update_component_metrics(component_metrics, status, duration_ms)
      component_metrics[:total_count].increment

      case status
      when 'success'
        component_metrics[:success_count].increment
      when 'error'
        component_metrics[:error_count].increment
      end

      update_duration_stats(component_metrics[:duration_stats], duration_ms)
    end

    def update_duration_stats(stats, duration_ms)
      stats[:total].increment((duration_ms * 100).to_i) # Store as hundredths to preserve decimals
      count = stats[:count].increment
      stats[:avg].set((stats[:total].value.to_f / count / 100).round(2))

      # Update min atomically
      stats[:min].update { |current| [current, duration_ms].min }

      # Update max atomically
      stats[:max].update { |current| [current, duration_ms].max }

      # Keep sliding window of durations for percentile calculation
      stats[:values] << duration_ms
      stats[:values].shift if stats[:values].size > 1000

      # Calculate P95
      values_array = stats[:values].to_a
      if values_array.size >= 20
        sorted = values_array.sort
        p95_index = (sorted.length * 0.95).ceil - 1
        stats[:p95].set(sorted[p95_index].round(2))
      elsif values_array.size.positive?
        # For small samples, use the max value as P95
        stats[:p95].set(values_array.max.round(2))
      end
    end

    def calculate_success_rate(metrics)
      total = metrics[:total_count].value
      return 0 if total.zero?

      ((metrics[:success_count].value.to_f / total) * 100).round(2)
    end

    def calculate_agent_health(total_operations, success_count)
      return :unknown if total_operations < 10 # Need minimum operations

      success_rate = (success_count.to_f / total_operations * 100)

      if success_rate >= 95
        :healthy
      elsif success_rate >= 80
        :degraded
      else
        :unhealthy
      end
    end

    def calculate_overall_success_rate(agents)
      return 0 if agents.empty?

      total_ops = agents.sum { |a| a[:total_operations] }
      return 0 if total_ops.zero?

      total_successes = agents.sum { |a| a[:total_successes] }
      ((total_successes.to_f / total_ops) * 100).round(2)
    end

    def serialize_error_breakdown(error_breakdown)
      error_breakdown.transform_values(&:value)
    end

    def operation_summary(metrics)
      {
        total_count: metrics[:total_count].value,
        success_count: metrics[:success_count].value,
        error_count: metrics[:error_count].value,
        success_rate: calculate_success_rate(metrics),
        avg_duration_ms: metrics[:duration_stats][:avg].value,
        p95_duration_ms: metrics[:duration_stats][:p95].value
      }
    end

    def default_component_metrics
      {
        component: 'Unknown',
        agent_id: 'unknown',
        total_operations: 0,
        success_count: 0,
        error_count: 0,
        success_rate: 0,
        avg_duration_ms: 0,
        p95_duration_ms: 0,
        operations: {}
      }
    end
  end
end
