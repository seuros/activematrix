# frozen_string_literal: true

require 'test_helper'
require 'active_matrix/telemetry'

class TelemetryTest < ActiveSupport::TestCase
  def setup
    # Reset telemetry state between tests
    ActiveMatrix::Telemetry.instance_variable_set(:@configured, false)
    ActiveMatrix::Telemetry.instance_variable_set(:@available, nil)
  end

  def teardown
    ActiveMatrix::Telemetry.shutdown if ActiveMatrix::Telemetry.configured?
  end

  test 'available? detects opentelemetry-sdk presence' do
    # This tests the detection mechanism works (result depends on gem availability)
    result = ActiveMatrix::Telemetry.available?
    assert [true, false].include?(result)
  end

  test 'configured? returns false before configure!' do
    refute ActiveMatrix::Telemetry.configured?
  end

  test 'tracer returns NullTracer when not configured' do
    tracer = ActiveMatrix::Telemetry.tracer
    assert_instance_of ActiveMatrix::Telemetry::NullTracer, tracer
  end

  test 'trace yields NullSpan when not configured' do
    span_received = nil
    ActiveMatrix::Telemetry.trace('test.operation') do |span|
      span_received = span
    end
    assert_instance_of ActiveMatrix::Telemetry::NullSpan, span_received
  end

  test 'NullSpan methods are no-ops' do
    span = ActiveMatrix::Telemetry::NullSpan.instance

    # These should not raise
    assert_nil span.set_attribute('key', 'value')
    assert_nil span.add_event('test_event')
    assert_nil span.record_exception(StandardError.new('test'))
    span.status = :ok
    assert true # Confirm we got here without error
  end

  test 'NullTracer yields NullSpan' do
    tracer = ActiveMatrix::Telemetry::NullTracer.instance
    span_received = nil

    tracer.in_span('test') do |span|
      span_received = span
    end

    assert_instance_of ActiveMatrix::Telemetry::NullSpan, span_received
  end

  test 'configure! with console exporter' do
    skip 'OpenTelemetry SDK not available' unless ActiveMatrix::Telemetry.available?

    result = ActiveMatrix::Telemetry.configure!(exporter: :console)
    assert result
    assert ActiveMatrix::Telemetry.configured?
  end

  test 'configure! returns true on second call (idempotent)' do
    skip 'OpenTelemetry SDK not available' unless ActiveMatrix::Telemetry.available?

    ActiveMatrix::Telemetry.configure!(exporter: :console)
    result = ActiveMatrix::Telemetry.configure!(exporter: :console)
    assert result
  end

  test 'tracer returns real tracer when configured' do
    skip 'OpenTelemetry SDK not available' unless ActiveMatrix::Telemetry.available?

    ActiveMatrix::Telemetry.configure!(exporter: :console)
    tracer = ActiveMatrix::Telemetry.tracer

    refute_instance_of ActiveMatrix::Telemetry::NullTracer, tracer
  end

  test 'trace creates real span when configured' do
    skip 'OpenTelemetry SDK not available' unless ActiveMatrix::Telemetry.available?

    # Suppress console output from the exporter
    ActiveMatrix::Telemetry.configure!(exporter: :console)

    span_class = nil
    capture_io do
      ActiveMatrix::Telemetry.trace('test.span', attributes: { 'test.attr' => 'value' }) do |span|
        span_class = span.class.name
      end
    end

    assert_includes span_class, 'Span'
    refute_equal 'ActiveMatrix::Telemetry::NullSpan', span_class
  end

  test 'record_exception is safe when not configured' do
    # Should not raise
    result = ActiveMatrix::Telemetry.record_exception(StandardError.new('test'))
    assert_nil result
  end

  test 'shutdown is safe when not configured' do
    # Should not raise
    result = ActiveMatrix::Telemetry.shutdown
    assert_nil result
  end

  test 'shutdown resets configured state' do
    skip 'OpenTelemetry SDK not available' unless ActiveMatrix::Telemetry.available?

    ActiveMatrix::Telemetry.configure!(exporter: :console)
    assert ActiveMatrix::Telemetry.configured?

    ActiveMatrix::Telemetry.shutdown
    refute ActiveMatrix::Telemetry.configured?
  end
end
