# frozen_string_literal: true

module ActiveMatrix
  # OpenTelemetry integration for ActiveMatrix
  #
  # Provides distributed tracing for:
  # - Agent lifecycle (connect, disconnect, error)
  # - Message handling
  # - Room operations
  # - Matrix API calls
  #
  # @example Enable with OTLP exporter
  #   ENV['OTEL_TRACES_EXPORTER'] = 'otlp'
  #   ENV['OTEL_SERVICE_NAME'] = 'activematrix'
  #   ActiveMatrix::Telemetry.configure!
  #
  # @example Enable with console exporter for debugging
  #   ActiveMatrix::Telemetry.configure!(exporter: :console)
  #
  module Telemetry
    TRACER_NAME = 'activematrix'
    TRACER_VERSION = ActiveMatrix::VERSION

    class << self
      # @return [Boolean] whether OpenTelemetry is available
      def available?
        @available ||= begin
          require 'opentelemetry/sdk'
          true
        rescue LoadError
          false
        end
      end

      # @return [Boolean] whether telemetry has been configured
      def configured?
        @configured ||= false
      end

      # Configure OpenTelemetry SDK for ActiveMatrix
      #
      # @param exporter [Symbol, nil] :console, :otlp, or nil for env-based config
      # @param service_name [String] service name for traces
      def configure!(exporter: nil, service_name: 'activematrix')
        return false unless available?
        return true if configured?

        require 'opentelemetry/sdk'

        case exporter
        when :console
          require 'opentelemetry/sdk'
          OpenTelemetry::SDK.configure do |c|
            c.service_name = service_name
            c.add_span_processor(
              OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
                OpenTelemetry::SDK::Trace::Export::ConsoleSpanExporter.new
              )
            )
          end
        when :otlp
          require 'opentelemetry/exporter/otlp'
          ENV['OTEL_SERVICE_NAME'] ||= service_name
          OpenTelemetry::SDK.configure
        else
          # Use environment variables
          ENV['OTEL_SERVICE_NAME'] ||= service_name
          OpenTelemetry::SDK.configure
        end

        @configured = true
      end

      # Get the ActiveMatrix tracer
      #
      # @return [OpenTelemetry::Trace::Tracer, NullTracer]
      def tracer
        return NullTracer.instance unless configured?

        OpenTelemetry.tracer_provider.tracer(TRACER_NAME, TRACER_VERSION)
      end

      # Trace a block of code
      #
      # @param name [String] span name
      # @param attributes [Hash] span attributes
      # @yield [span] the current span
      def trace(name, attributes: {}, kind: :internal, &)
        return yield(NullSpan.instance) unless configured?

        tracer.in_span(name, attributes: attributes, kind: kind, &)
      end

      # Record an exception on the current span
      #
      # @param exception [Exception]
      # @param attributes [Hash] additional attributes
      def record_exception(exception, attributes: {})
        return unless configured?

        span = OpenTelemetry::Trace.current_span
        span.record_exception(exception, attributes: attributes)
        span.status = OpenTelemetry::Trace::Status.error(exception.message)
      end

      # Shutdown the tracer provider
      def shutdown
        return unless configured?

        OpenTelemetry.tracer_provider.shutdown
        @configured = false
      end
    end

    # Null tracer for when OTel is not available
    class NullTracer
      include Singleton

      def in_span(_name, **_opts)
        yield NullSpan.instance
      end
    end

    # Null span for when OTel is not available
    class NullSpan
      include Singleton

      def set_attribute(_key, _value); end
      def add_event(_name, **_opts); end
      def record_exception(_exception, **_opts); end
      def status=(_status); end
    end
  end
end
