# frozen_string_literal: true

require 'test_helper'

class MXIDTest < ActiveSupport::TestCase
  def test_creation
    user = ActiveMatrix::MXID.new '@user:example.com'
    room_id = ActiveMatrix::MXID.new '!opaque:example.com'
    event = ActiveMatrix::MXID.new '$opaque:example.com'
    event3 = ActiveMatrix::MXID.new '$0paqu3+strin6+w1th+special/chars'
    group = ActiveMatrix::MXID.new '+group:example.com'
    room_alias = ActiveMatrix::MXID.new '#alias:example.com'

    assert_predicate user, :valid?
    assert_predicate room_id, :valid?
    assert_predicate event, :valid?
    assert_predicate event3, :valid?
    assert_predicate group, :valid?
    assert_predicate room_alias, :valid?

    assert_predicate user, :user?
    assert_predicate room_id, :room?
    assert_predicate room_id, :room_id?
    assert_not room_id.room_alias?
    assert_predicate event, :event?
    assert_predicate event3, :event?
    assert_predicate group, :group?
    assert_predicate room_alias, :room?
    assert_not room_alias.room_id?
    assert_predicate room_alias, :room_alias?
  end

  def test_to_s
    input = %w[@user:example.com !opaque:example.com $opaque:example.com $0paqu3+strin6+w1th+special/chars +group:example.com #alias:example.com]
    input.each do |mxid|
      parsed = ActiveMatrix::MXID.new mxid

      assert_equal mxid, parsed.to_s
      assert_equal mxid, parsed
      assert_equal parsed, mxid
    end
  end

  def test_parse
    input = %w[@user:example.com !opaque:example.com $opaque:example.com +group:example.com #alias:example.com]

    input.each do |mxid|
      parsed = ActiveMatrix::MXID.new mxid

      assert_equal 'example.com', parsed.domain
    end

    assert_nil ActiveMatrix::MXID.new('$0paqu3+strin6+w1th+special/chars').domain
    assert_nil ActiveMatrix::MXID.new('@user:example.com').port
    parsed = ActiveMatrix::MXID.new '#room:matrix.example.com:8448'

    assert_equal '#', parsed.sigil
    assert_equal 'room', parsed.localpart
    assert_equal 'matrix.example.com', parsed.domain
    assert_equal 8448, parsed.port

    assert_equal '#room:matrix.example.com:8448', parsed.to_s
  end

  def test_parse_failures
    assert_raises(ArgumentError) { ActiveMatrix::MXID.new nil }
    assert_raises(ArgumentError) { ActiveMatrix::MXID.new true }
    assert_raises(ArgumentError) { ActiveMatrix::MXID.new '#asdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfadsfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfadsfasdfadsfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdf:example.com' }
    assert_raises(ArgumentError) { ActiveMatrix::MXID.new '' }
    assert_raises(ArgumentError) { ActiveMatrix::MXID.new 'user:example.com' }
    assert_raises(ArgumentError) { ActiveMatrix::MXID.new '@user' }
  end
end
