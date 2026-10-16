# frozen_string_literal: true

require 'test_helper'

class DeliveriesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET = 's' * 32
  # The same vector the daemon's Rust tests check (delivery/signature/tests.rs).
  VECTOR_BODY = '{"rooms":[{"agent_id":"0199e1a2-0000-7000-8000-000000000000","room_id":"!room:matrix.test"}]}'
  VECTOR_SIGNATURE = 'sha256=6c35f7a6837917d8ab0d029600626d9f7867b31fe2fc24b0886aa954370bbb7d'

  setup { ActiveMatrix.config.delivery_secret = SECRET }
  teardown { ActiveMatrix.config.delivery_secret = nil }

  test 'signs exactly as the daemon does' do
    assert_equal VECTOR_SIGNATURE, ActiveMatrix::DeliverySignature.sign(SECRET, 1_760_000_000, VECTOR_BODY)
  end

  test 'a signed push enqueues one drain job per room' do
    body = { rooms: [{ agent_id: 'a1', room_id: '!r1:m' }, { agent_id: 'a1', room_id: '!r2:m' }] }.to_json

    push body

    assert_response :accepted
    assert_enqueued_with(job: ActiveMatrix::DrainRoomJob, args: ['a1', '!r1:m'])
    assert_enqueued_with(job: ActiveMatrix::DrainRoomJob, args: ['a1', '!r2:m'])
  end

  test 'a bad or stale signature is refused' do
    push({ rooms: [] }.to_json, signature: 'sha256=forged')

    assert_response :unauthorized

    push({ rooms: [] }.to_json, timestamp: Time.now.to_i - 3600)

    assert_response :unauthorized
    assert_no_enqueued_jobs
  end

  test 'a malformed push is a bad request' do
    push '{"rooms": "nope"}'

    assert_response :bad_request
  end

  test 'without a secret configured the endpoint is unavailable' do
    ActiveMatrix.config.delivery_secret = nil

    push({ rooms: [] }.to_json)

    assert_response :service_unavailable
  end

  private

  def push(body, timestamp: Time.now.to_i, signature: nil)
    signature ||= ActiveMatrix::DeliverySignature.sign(SECRET, timestamp, body)
    post '/active_matrix/deliveries', params: body,
                                      headers: { 'Content-Type' => 'application/json',
                                                 'X-ActiveMatrix-Timestamp' => timestamp.to_s,
                                                 'X-ActiveMatrix-Signature' => signature }
  end
end
