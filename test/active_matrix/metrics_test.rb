# frozen_string_literal: true

require 'test_helper'

class MetricsTest < ActiveSupport::TestCase
  def setup
    @metrics = ActiveMatrix::Metrics.instance
    @metrics.reset!
  end

  def teardown
    @metrics.reset!
  end

  test 'record_operation tracks successful operations' do
    @metrics.record_operation(
      :send_message,
      component: 'MessageDispatcher',
      agent_id: 'agent_1',
      status: 'success',
      duration_ms: 50.0
    )

    agent_metrics = @metrics.get_agent_metrics('agent_1')

    assert_equal 1, agent_metrics[:total_operations]
    assert_equal 1, agent_metrics[:total_successes]
    assert_equal 0, agent_metrics[:total_errors]
    assert_equal 100.0, agent_metrics[:overall_success_rate]
  end

  test 'record_operation tracks error operations' do
    @metrics.record_operation(
      :send_message,
      component: 'MessageDispatcher',
      agent_id: 'agent_1',
      status: 'error',
      duration_ms: 100.0,
      error_class: 'ActiveMatrix::MatrixRequestError'
    )

    agent_metrics = @metrics.get_agent_metrics('agent_1')

    assert_equal 1, agent_metrics[:total_operations]
    assert_equal 0, agent_metrics[:total_successes]
    assert_equal 1, agent_metrics[:total_errors]
  end

  test 'record_operation tracks error breakdown' do
    2.times do
      @metrics.record_operation(
        :send_message,
        component: 'MessageDispatcher',
        agent_id: 'agent_1',
        status: 'error',
        duration_ms: 50.0,
        error_class: 'Timeout::Error'
      )
    end

    @metrics.record_operation(
      :send_message,
      component: 'MessageDispatcher',
      agent_id: 'agent_1',
      status: 'error',
      duration_ms: 50.0,
      error_class: 'SocketError'
    )

    agent_metrics = @metrics.get_agent_metrics('agent_1')
    error_breakdown = agent_metrics[:components]['MessageDispatcher'][:operations]['send_message'][:error_breakdown]

    assert_equal 2, error_breakdown['Timeout::Error']
    assert_equal 1, error_breakdown['SocketError']
  end

  test 'get_component_metrics returns component-specific data' do
    @metrics.record_operation(
      :send_message,
      component: 'MessageDispatcher',
      agent_id: 'agent_1',
      status: 'success',
      duration_ms: 25.0
    )

    @metrics.record_operation(
      :set_presence,
      component: 'PresenceManager',
      agent_id: 'agent_1',
      status: 'success',
      duration_ms: 10.0
    )

    component_metrics = @metrics.get_component_metrics('agent_1', 'MessageDispatcher')

    assert_equal 'MessageDispatcher', component_metrics[:component]
    assert_equal 1, component_metrics[:total_operations]
    assert component_metrics[:operations].key?('send_message')
  end

  test 'top_operations_by_volume returns sorted operations' do
    10.times { record_operation('op_a', 'agent_1') }
    5.times { record_operation('op_b', 'agent_1') }
    15.times { record_operation('op_c', 'agent_1') }

    top = @metrics.top_operations_by_volume('agent_1', limit: 2)

    assert_equal 2, top.size
    assert_equal 'op_c', top[0][:operation]
    assert_equal 15, top[0][:count]
    assert_equal 'op_a', top[1][:operation]
    assert_equal 10, top[1][:count]
  end

  test 'recent_errors returns errors sorted by timestamp' do
    @metrics.record_operation(
      :op1,
      component: 'Test',
      agent_id: 'agent_1',
      status: 'error',
      duration_ms: 10.0,
      error_class: 'Error1'
    )

    sleep(0.01) # Ensure different timestamps

    @metrics.record_operation(
      :op2,
      component: 'Test',
      agent_id: 'agent_1',
      status: 'error',
      duration_ms: 20.0,
      error_class: 'Error2'
    )

    errors = @metrics.recent_errors('agent_1', limit: 10)

    assert_equal 2, errors.size
    assert_equal 'op2', errors[0][:operation]
    assert_equal 'op1', errors[1][:operation]
  end

  test 'get_health_summary aggregates all agents' do
    5.times { record_operation('op', 'agent_1', status: 'success') }
    5.times { record_operation('op', 'agent_1', status: 'success') }
    10.times { record_operation('op', 'agent_2', status: 'success') }

    summary = @metrics.get_health_summary

    assert_equal 2, summary[:total_agents]
    assert_equal 20, summary[:total_operations]
  end

  test 'reset_agent! clears only specified agent metrics' do
    record_operation('op', 'agent_1')
    record_operation('op', 'agent_2')

    @metrics.reset_agent!('agent_1')

    assert_empty @metrics.get_agent_metrics('agent_1')
    refute_empty @metrics.get_agent_metrics('agent_2')
  end

  test 'health_status returns correct status based on success rate' do
    # Need at least 10 operations for health calculation
    10.times { record_operation('op', 'agent_1', status: 'success') }

    agent_metrics = @metrics.get_agent_metrics('agent_1')
    assert_equal :healthy, agent_metrics[:health_status]

    # Add 2 failures to degrade health (10/12 = 83% which is degraded)
    2.times { record_operation('op', 'agent_1', status: 'error') }

    agent_metrics = @metrics.get_agent_metrics('agent_1')
    assert_equal :degraded, agent_metrics[:health_status]

    # Add more failures to make it unhealthy (10/17 = 59% which is unhealthy)
    5.times { record_operation('op', 'agent_1', status: 'error') }

    agent_metrics = @metrics.get_agent_metrics('agent_1')
    assert_equal :unhealthy, agent_metrics[:health_status]
  end

  private

  def record_operation(operation, agent_id, status: 'success')
    @metrics.record_operation(
      operation,
      component: 'Test',
      agent_id: agent_id,
      status: status,
      duration_ms: rand(10..100).to_f
    )
  end
end
