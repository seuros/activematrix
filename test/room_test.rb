# frozen_string_literal: true

require 'test_helper'

class RoomTest < ActiveSupport::TestCase
  def setup
    # Silence debugging output
    ::ActiveMatrix.logger.level = :error

    # Clear Rails cache before each test
    Rails.cache.clear if defined?(Rails) && Rails.respond_to?(:cache)

    @http = mock
    @http.stubs(:active?).returns(true)

    @api = ActiveMatrix::Api.new 'https://example.com', protocols: :CS
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)

    @client = ActiveMatrix::Client.new @api
    @client.stubs(:mxid).returns('@alice:example.com')

    @id = '!room:example.com'
    @client.send :ensure_room, @id
    @room = @client.rooms.first

    # Clear any pre-populated members from previous tests
    @room.instance_variable_set(:@pre_populated_members, nil)

    # Stub API version check for all tests
    @api.stubs(:client_api_versions).returns(ActiveMatrix::Response.new(@api, versions: ['r0.1.0', 'r0.2.0']))
  end

  def test_pre_joined_members
    users = [ActiveMatrix::User.new(@client, '@alice:example.com', display_name: 'Alice')]
    users.each do |u|
      @room.send :ensure_member, u
    end

    @api.expects(:get_room_members).never
    @api.expects(:get_room_joined_members).never

    assert_equal users, @room.joined_members
  end

  def test_joined_members
    assert_equal :all, @room.client.cache

    @api.expects(:get_room_joined_members).with('!room:example.com').returns(
      joined: {
        '@alice:example.com': {
          display_name: 'Alice'
        },
        '@charlie:example.com': {
          display_name: 'Charlie'
        }
      }
    )

    assert_equal 2, @room.joined_members.count
    assert_equal '@alice:example.com', @room.joined_members.first.id
    assert_equal '@charlie:example.com', @room.joined_members.last.id
    assert @room.dm?(members_only: true)
  end

  def test_dm
    @api.expects(:get_room_joined_members).with('!room:example.com').returns(
      joined: {
        '@alice:example.com': {},
        '@bob:example.com': {},
        '@charlie:example.com': {}
      }
    )

    refute @room.dm?(members_only: true)

    @api.expects(:get_account_data).with('@alice:example.com', 'm.direct').returns(
      '@bob:example.com' => [@id]
    )

    assert @room.dm?
  end

  def test_all_members
    assert_equal :all, @room.client.cache

    @client.expects(:get_user).twice.with('@alice:example.com').returns(ActiveMatrix::User.new(@client, '@alice:example.com'))
    @client.expects(:get_user).once.with('@charlie:example.com').returns(ActiveMatrix::User.new(@client, '@charlie:example.com'))

    if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.7.0')
      @api.expects(:get_room_members).once.with('!room:example.com').returns(chunk: [{ state_key: '@alice:example.com' }])
    else
      @api.expects(:get_room_members).once.with('!room:example.com', {}).returns(chunk: [{ state_key: '@alice:example.com' }])
    end

    # Two calls, cache should be kept
    assert_equal 1, @room.all_members.count
    assert_equal '@alice:example.com', @room.all_members.first.id

    @api.expects(:get_room_members).once.with('!room:example.com', filter: 'something').returns(
      chunk: [
        {
          state_key: '@alice:example.com'
        },
        {
          state_key: '@charlie:example.com'
        }
      ]
    )

    # Filter, should skip cache and return another value
    members = @room.all_members(filter: 'something')
    assert_equal 2, members.count
    assert_equal '@alice:example.com', members.first.id
    assert_equal '@charlie:example.com', members.last.id

    # No filter, should return to cached data
    assert_equal 1, @room.all_members.count
    assert_equal '@alice:example.com', @room.all_members.first.id
  end

  def test_wrapped_methods
    # Temporarily set cache to :none to avoid serialization issues with mocks
    original_cache = @client.instance_variable_get(:@cache)
    @client.instance_variable_set(:@cache, :none)

    text = '<b>test</b>'
    @api.expects(:send_message).with(@id, text)
    @room.send_text(text)

    @api.expects(:send_message_event).with(@id, 'm.room.message', body: 'test', msgtype: 'm.text', formatted_body: text, format: 'org.matrix.custom.html')
    @room.send_html(text)

    @api.expects(:send_emote).with(@id, text)
    @room.send_emote(text)

    @api.expects(:send_content).with(@id, 'mxc://example.com/file', text, 'm.file', extra_information: {})
    @room.send_file('mxc://example.com/file', text)

    @api.expects(:send_notice).with(@id, text)
    @room.send_notice(text)

    @api.expects(:send_content).with(@id, 'mxc://example.com/file', text, 'm.image', extra_information: {})
    @room.send_image('mxc://example.com/file', text)

    @api.expects(:send_location).with(@id, 'geo:1,2,3', text, thumbnail_url: nil, thumbnail_info: {})
    @room.send_location('geo:1,2,3', text)

    @api.expects(:send_content).with(@id, 'mxc://example.com/file', text, 'm.video', extra_information: {})
    @room.send_video('mxc://example.com/file', text)

    @api.expects(:send_content).with(@id, 'mxc://example.com/file', text, 'm.audio', extra_information: {})
    @room.send_audio('mxc://example.com/file', text)

    @api.expects(:redact_event).with(@id, '$event:example.com', reason: text)
    @room.redact_message('$event:example.com', text)

    @api.expects(:invite_user).with(@id, '@bob:example.com')
    @room.invite_user('@bob:example.com')

    @api.expects(:kick_user).with(@id, '@bob:example.com', reason: text)
    @room.kick_user('@bob:example.com', text)

    @api.expects(:ban_user).with(@id, '@bob:example.com', reason: text)
    @room.ban_user('@bob:example.com', text)

    @api.expects(:unban_user).with(@id, '@bob:example.com')
    @room.unban_user('@bob:example.com')

    @api.expects(:leave_room).with(@id)
    @client.instance_variable_get(:@rooms).expects(:delete).with(@id)
    @room.leave

    @api.expects(:get_room_account_data).with('@alice:example.com', @id, 'com.example.Test')
    @room.get_account_data('com.example.Test')

    @api.expects(:set_room_account_data).with('@alice:example.com', @id, 'com.example.Test', data: true)
    @room.set_account_data('com.example.Test', data: true)

    @api.expects(:get_membership).with(@id, '@alice:example.com').returns(membership: 'join')
    @api.expects(:set_membership).with(@id, '@alice:example.com', 'join', 'Updating room profile information', membership: 'join', displayname: 'Alice',
                                                                                                               avatar_url: 'mxc://example.com/avatar')
    @room.set_user_profile display_name: 'Alice', avatar_url: 'mxc://example.com/avatar'

    @api.expects(:get_user_tags).with('@alice:example.com', @id).returns(tags: { 'example.tag': {} })
    tags = @room.tags

    @api.expects(:add_user_tag).with('@alice:example.com', @id, :'test.tag', data: true)
    tags.add 'test.tag', data: true

    @api.expects(:remove_user_tag).with('@alice:example.com', @id, :'test.tag')
    tags.remove 'test.tag'

    assert_nil tags[:'test.tag']
    assert_not_nil tags[:'example.tag']

    expect_message(@api, :set_room_state, @id, 'm.room.name', { name: 'name' })
    @room.name = 'name'

    expect_message(@api, :set_room_state, @id, 'm.room.topic', { topic: 'topic' })
    @room.topic = 'topic'

    @api.expects(:request).with(
      :put,
      :client_r0,
      '/directory/room/%23room%3Aexample.com',
      body: { room_id: '!room:example.com' },
      query: {}
    )
    @room.add_alias('#room:example.com')

    expect_message(@api, :set_room_state, @id, 'm.room.join_rules', { join_rule: :invite }).twice
    @room.invite_only = true
    @room.join_rule = :invite

    expect_message(@api, :set_room_state, @id, 'm.room.join_rules', { join_rule: :public }).twice
    @room.invite_only = false
    @room.join_rule = :public

    expect_message(@api, :set_room_state, @id, 'm.room.guest_access', { guest_access: :can_join }).twice
    @room.allow_guests = true
    @room.guest_access = :can_join

    expect_message(@api, :set_room_state, @id, 'm.room.guest_access', { guest_access: :forbidden }).twice
    @room.allow_guests = false
    @room.guest_access = :forbidden

    # Set up power levels expectation - called many times
    power_levels_data = { users: { '@alice:example.com': 100, '@bob:example.com': 50 }, users_default: 0 }
    @api.expects(:get_room_state).with(@id, 'm.room.power_levels').at_least_once.returns(power_levels_data)

    @room.power_levels

    assert @room.admin? '@alice:example.com'
    assert @room.moderator? '@alice:example.com'
    assert @room.moderator? '@bob:example.com'
    refute @room.moderator? '@charlie:example.com'

    assert @room.user_can_send? '@alice:example.com', 'm.room.message'
    assert @room.user_can_send? '@alice:example.com', 'm.room.name', state: true
    refute @room.user_can_send? '@charlie:example.com', 'm.room.topic', state: true

    @api.expects(:set_room_state).with(@id, 'm.room.power_levels', { users: { '@alice:example.com': 100, '@bob:example.com': 50, '@charlie:example.com': 50 }, users_default: 0 })
    @room.moderator! '@charlie:example.com'

    @api.expects(:set_room_state).with(@id, 'm.room.power_levels', { users: { '@alice:example.com': 100, '@bob:example.com': 50, '@charlie:example.com': 100 }, users_default: 0 })
    @room.admin! '@charlie:example.com'
  ensure
    # Restore original cache setting
    @client.instance_variable_set(:@cache, original_cache) if defined?(original_cache)
  end

  def test_state_refresh
    @api.expects(:get_room_state).with(@id, 'm.room.name').returns name: 'New name'
    @room.reload_name!

    assert_equal 'New name', @room.name

    @api.expects(:get_room_state).with(@id, 'm.room.topic').returns topic: 'New topic'
    @room.reload_topic!

    assert_equal 'New topic', @room.topic

    # Allow get_room_state to be called multiple times during the test
    @api.stubs(:get_room_state).with(@id, 'm.room.canonical_alias').returns(ActiveMatrix::Response.new(@api, alias: '#test:example.com'))
    @api.expects(:get_room_aliases).with(@id).never

    aliases = @room.aliases
    assert aliases.is_a?(Array), "Expected aliases to be an Array, got #{aliases.class}"
    assert aliases.include?('#test:example.com'), "Expected aliases #{aliases.inspect} to include '#test:example.com'"

    # Second call should use cache
    assert @room.aliases.include? '#test:example.com'

    # Test reload with alt_aliases
    @api.stubs(:get_room_state).with(@id, 'm.room.canonical_alias').returns(ActiveMatrix::Response.new(@api, alias: '#test:example.com', alt_aliases: ['#test:example1.com']))
    @room.reload_aliases!
    assert @room.aliases.include? '#test:example.com'
    assert @room.aliases.include? '#test:example1.com'

    # Test with get_room_aliases
    @api.expects(:get_room_aliases).with(@id).returns(ActiveMatrix::Response.new(@api, aliases: ['#test:example2.com']))
    @room.reload_aliases!
    aliases = @room.aliases(canonical_only: false)
    assert aliases.include? '#test:example.com'
    assert aliases.include? '#test:example1.com'
    assert aliases.include? '#test:example2.com'

    @api.expects(:get_room_state).with(@id, 'm.room.canonical_alias').raises(ActiveMatrix::MatrixNotFoundError)
    @api.expects(:get_room_aliases).with(@id).returns(ActiveMatrix::Response.new(@api, aliases: ['#test:example.com']))
    @room.reload_aliases!
    assert @room.aliases(canonical_only: false).include? '#test:example.com'

    @api.expects(:get_room_state).with(@id, 'm.room.canonical_alias').raises(ActiveMatrix::MatrixNotFoundError)
    @api.expects(:get_room_aliases).with(@id).returns(ActiveMatrix::Response.new(@api, aliases: ['#test2:example.com']))
    @room.reload_aliases!
    assert @room.aliases(canonical_only: false).include?('#test2:example.com')

    # Unstub the previous stub and set new expectation
    @api.unstub(:get_room_state)
    # Expect get_room_state to be called twice - once by reload_aliases! and once by aliases
    @api.expects(:get_room_state).with(@id, 'm.room.canonical_alias').raises(ActiveMatrix::MatrixNotFoundError).twice
    @api.expects(:get_room_aliases).with(@id).returns(ActiveMatrix::Response.new(@api, aliases: ['#test2:example.com']))
    @room.reload_aliases!
    assert !@room.aliases(canonical_only: false).include?('#test:example.com')
  end

  def test_modifies
    @api.expects(:get_room_state).with(@id, 'm.room.power_levels').returns users_default: 0, redact: 50

    @api.expects(:set_room_state).with(@id, 'm.room.power_levels', users_default: 5, redact: 50, users: { '@alice:example.com': 100 })
    @room.modify_user_power_levels({ '@alice:example.com': 100 }, 5)

    @api.expects(:get_room_state).with(@id, 'm.room.power_levels').returns users_default: 0, redact: 50
    @api.expects(:set_room_state).with(@id, 'm.room.power_levels', users_default: 0, redact: 50, events: { 'm.room.message': 100 })
    @room.modify_required_power_levels 'm.room.message': 100
  end
end
