# frozen_string_literal: true

require 'test_helper'

class RoomTest < ActiveSupport::TestCase
  setup do
    @agent = create_agent
    @room = insert_room(@agent, name: 'Ops')
  end

  test 'mirrored rows are read-only from Rails' do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @room.update!(name: 'Renamed') }
  end

  test 'state reads the current content for a type and state key' do
    insert_state(@room, 'm.room.topic', { 'topic' => 'deploys' })
    insert_state(@room, 'm.room.member', { 'membership' => 'join' }, state_key: '@bob:matrix.test')

    assert_equal({ 'topic' => 'deploys' }, @room.state('m.room.topic'))
    assert_equal 'join', @room.state('m.room.member', '@bob:matrix.test')['membership']
    assert_nil @room.state('m.room.name')
  end

  test 'power levels: explicit entry, then users_default' do
    insert_state(@room, 'm.room.power_levels', { 'users' => { '@mod:matrix.test' => 50 }, 'users_default' => 10 })

    assert_equal 50, @room.power_level('@mod:matrix.test')
    assert_equal 10, @room.power_level('@anyone:matrix.test')
  end

  test 'without a power levels event the creator has 100' do
    insert_state(@room, 'm.room.create', { 'room_version' => '11' }, sender: '@founder:matrix.test')

    assert_equal 100, @room.power_level('@founder:matrix.test')
    assert_equal 0, @room.power_level('@anyone:matrix.test')
  end

  test 'from room version 12 creators outrank every power level' do
    insert_state(@room, 'm.room.create',
                 { 'room_version' => '12', 'additional_creators' => ['@cofounder:matrix.test'] },
                 sender: '@founder:matrix.test')
    insert_state(@room, 'm.room.power_levels', { 'users' => { '@founder:matrix.test' => 0 } })

    assert_equal Float::INFINITY, @room.power_level('@founder:matrix.test')
    assert_equal Float::INFINITY, @room.power_level('@cofounder:matrix.test')
  end

  test 'members follow the composite (agent, room) key' do
    insert_member(@room, '@alice:matrix.test')
    insert_member(@room, '@bob:matrix.test', membership: 'leave')
    other = insert_room(create_agent, room_id: @room.room_id)
    insert_member(other, '@carol:matrix.test')

    assert_equal ['@alice:matrix.test'], @room.joined_members.pluck(:user_id)
    assert_equal 2, @room.members.count
  end
end
