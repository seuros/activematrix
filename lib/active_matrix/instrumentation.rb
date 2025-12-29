# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/notifications'
require 'timeout'
require 'socket'
require 'json'

module ActiveMatrix
  # Instrumentation module for Matrix bot operations
  # Provides ActiveSupport::Notifications events and structured logging
  #
  # @example Include in a class
  #   class MyService
  #     include ActiveMatrix::Instrumentation
  #
  #     def perform
  #       instrument_operation(:my_operation, room_id: '!abc:matrix.org') do
  #         # ... operation code
  #       end
  #     end
  #   end
  #
  module Instrumentation
    extend ActiveSupport::Concern

    private

    # Instrument a Matrix bot operation with timing and result tracking
    #
    # @param operation [Symbol, String] Operation name (e.g., :send_message, :sync)
    # @param metadata [Hash] Additional context to include in the event
    # @yield Block to execute and instrument
    # @return [Object] Result of the block
    # @raise [StandardError] Re-raises any exception after logging
    def instrument_operation(operation, **metadata)
      event_data = metadata.merge(
        operation: operation,
        agent_id: respond_to?(:agent_id) ? agent_id : nil,
        component: self.class.name&.demodulize || 'Unknown'
      )

      ActiveSupport::Notifications.instrument(
        "activematrix.#{operation}",
        event_data
      ) do |payload|
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          result = yield

          payload[:status] = 'success'
          payload[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
          payload[:result] = summarize_result(result)

          log_operation_result(operation, 'SUCCESS', payload)

          result
        rescue StandardError => e
          payload[:status] = 'error'
          payload[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
          payload[:error_class] = e.class.name
          payload[:error_message] = e.message
          payload[:error_category] = classify_error(e)

          log_operation_result(operation, 'ERROR', payload)

          raise
        end
      end
    end

    # Classify errors for better monitoring and alerting
    #
    # @param error [StandardError] The error to classify
    # @return [String] Error category
    def classify_error(error)
      case error
      when Timeout::Error
        'timeout'
      when SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH
        'network'
      when JSON::ParserError
        'parse'
      when OpenSSL::SSL::SSLError
        'ssl'
      else
        case error.class.name
        when /ActiveMatrix::Errors::MatrixConnectionError/
          'matrix_connection'
        when /ActiveMatrix::Errors::MatrixRequestError/
          'matrix_request'
        when /ActiveMatrix::Errors::MatrixNotAuthorizedError/
          'matrix_auth'
        when /ActiveMatrix::Errors::MatrixForbiddenError/
          'matrix_forbidden'
        when /ActiveMatrix::Errors::MatrixNotFoundError/
          'matrix_not_found'
        when /PG::/
          'database'
        else
          'application'
        end
      end
    end

    # Log operation result with structured data
    #
    # @param operation [Symbol, String] Operation name
    # @param status [String] 'SUCCESS' or 'ERROR'
    # @param data [Hash] Event payload data
    def log_operation_result(operation, status, data)
      component = data[:component] || 'Unknown'
      agent_id = data[:agent_id] || 'unknown'

      message = "#{operation} - #{status}"
      message += " (#{data[:duration_ms]}ms)" if data[:duration_ms]
      message = "[#{component}][agent:#{agent_id}] #{message}"

      if status == 'ERROR'
        ActiveMatrix.logger.error("#{message}: #{data[:error_class]} - #{data[:error_message]}")
      else
        ActiveMatrix.logger.debug(message)
      end
    end

    # Summarize result for logging without exposing sensitive data
    #
    # @param result [Object] The result to summarize
    # @return [String] Human-readable summary
    def summarize_result(result)
      case result
      when String
        result.length > 100 ? "#{result[0...97]}..." : result
      when Numeric, true, false
        result.to_s
      when nil
        'nil'
      when Hash
        "Hash(#{result.keys.size} keys)"
      when Array
        "Array(#{result.size} items)"
      else
        result.class.name
      end
    end
  end
end
