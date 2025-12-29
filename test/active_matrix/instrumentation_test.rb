# frozen_string_literal: true

require 'test_helper'

class InstrumentationTest < ActiveSupport::TestCase
  class InstrumentedService
    include ActiveMatrix::Instrumentation

    attr_reader :agent_id

    def initialize(agent_id: 'test_agent')
      @agent_id = agent_id
    end

    def successful_operation
      instrument_operation(:test_operation, room_id: '!test:matrix.org') do
        'success result'
      end
    end

    def failing_operation
      instrument_operation(:failing_operation, room_id: '!test:matrix.org') do
        raise StandardError, 'Test error'
      end
    end

    def timeout_operation
      instrument_operation(:timeout_operation) do
        raise Timeout::Error, 'Connection timed out'
      end
    end
  end

  def setup
    @service = InstrumentedService.new
    @notifications = []

    @subscription = ActiveSupport::Notifications.subscribe(/^activematrix\./) do |name, start, finish, id, payload|
      @notifications << {
        name: name,
        start: start,
        finish: finish,
        id: id,
        payload: payload
      }
    end
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscription)
  end

  test 'instrument_operation wraps successful operations' do
    result = @service.successful_operation

    assert_equal 'success result', result
    assert_equal 1, @notifications.size

    notification = @notifications.first
    assert_equal 'activematrix.test_operation', notification[:name]
    assert_equal 'success', notification[:payload][:status]
    assert notification[:payload][:duration_ms] >= 0, 'duration_ms should be non-negative'
    assert_equal '!test:matrix.org', notification[:payload][:room_id]
  end

  test 'instrument_operation captures and re-raises errors' do
    assert_raises(StandardError) do
      @service.failing_operation
    end

    assert_equal 1, @notifications.size

    notification = @notifications.first
    assert_equal 'error', notification[:payload][:status]
    assert_equal 'StandardError', notification[:payload][:error_class]
    assert_equal 'Test error', notification[:payload][:error_message]
  end

  test 'classify_error returns correct category for timeout' do
    assert_raises(Timeout::Error) do
      @service.timeout_operation
    end

    notification = @notifications.first
    assert_equal 'timeout', notification[:payload][:error_category]
  end

  test 'instrument_operation includes component name' do
    @service.successful_operation

    notification = @notifications.first
    assert_equal 'InstrumentedService', notification[:payload][:component]
  end

  test 'instrument_operation includes agent_id' do
    @service.successful_operation

    notification = @notifications.first
    assert_equal 'test_agent', notification[:payload][:agent_id]
  end
end
