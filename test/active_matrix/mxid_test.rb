# frozen_string_literal: true

require 'test_helper'

class MXIDTest < ActiveSupport::TestCase
  VALID = {
    '@alice:matrix.org' => [:user_id, 'alice', 'matrix.org'],
    '@bot:localhost:8448' => [:user_id, 'bot', 'localhost:8448'],
    '@ops:[::1]:8448' => [:user_id, 'ops', '[::1]:8448'],
    '@ops:192.168.1.10' => [:user_id, 'ops', '192.168.1.10'],
    '!opaque:matrix.org' => [:room_id, 'opaque', 'matrix.org'],
    '!31hneApxJ_1o-63DmFrpeqnkFfWppnzWso1JvH3ogLM' => [:room_id, '31hneApxJ_1o-63DmFrpeqnkFfWppnzWso1JvH3ogLM', nil],
    '#ops:matrix.org' => [:room_alias, 'ops', 'matrix.org'],
    '$acR1l0raoZnm60CBwAVgqbZqoO/mYU81xysh1u7XcJk' => [:event_id, 'acR1l0raoZnm60CBwAVgqbZqoO/mYU81xysh1u7XcJk', nil],
    '$Rqnc-F-dvnEYJTyHq_iKxU2bZ1CI92-kuZq3a5lr5Zg' => [:event_id, 'Rqnc-F-dvnEYJTyHq_iKxU2bZ1CI92-kuZq3a5lr5Zg', nil],
    '$1234:example.org' => [:event_id, '1234', 'example.org']
  }.freeze

  INVALID = [
    '', 'alice', '@alice', '@alice:', '@:matrix.org', "@alice:matrix.org\ngarbage", '@al ice:matrix.org',
    '+group:matrix.org', '!short', '@alice:matrix.org:99999', '@alice:-bad-.org', "@#{'a' * 260}:matrix.org"
  ].freeze

  test 'parses what the spec allows' do
    VALID.each do |identifier, (type, localpart, server_name)|
      mxid = ActiveMatrix::MXID.parse(identifier)

      assert_equal [type, localpart, server_name], [mxid.type, mxid.localpart, mxid.server_name], identifier
      assert_equal identifier, mxid.to_s, identifier
    end
  end

  test 'rejects what it does not' do
    INVALID.each do |identifier|
      assert_raises(ArgumentError, identifier.inspect) { ActiveMatrix::MXID.parse(identifier) }
      assert_not ActiveMatrix::MXID.valid?(identifier), identifier.inspect
    end
  end

  test 'compares with strings and works as a hash key' do
    mxid = ActiveMatrix::MXID.parse('@alice:matrix.org')

    assert_equal '@alice:matrix.org', mxid
    assert_equal(1, { mxid => 1 }[ActiveMatrix::MXID.parse('@alice:matrix.org')])
    assert_predicate mxid, :user?
    assert_predicate ActiveMatrix::MXID.parse('#ops:matrix.org'), :room?
  end
end
