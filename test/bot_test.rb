# frozen_string_literal: true

require 'test_helper'
require 'net/http'

class BotTest < ActiveSupport::TestCase
  class ExampleBot < ActiveMatrix::Bot::Base
    set :testing, true

    command :test do |_arg, _arg2 = nil|
      # ARG [ARG2]
      bot.send :test_executed
    end

    command :test_arr do |*_args|
      # [ARGS...]
      bot.send :test_arr_executed
    end

    command :test_only, only: :dm do
      bot.send :test_only
    end

    command :test_event do
      bot.send :test_event, event.event_id
    end

    command(:test_only_proc, only: -> { room.user_can_send? client.mxid, 'm.reaction' }) do
      bot.send :test_only_proc
    end

    event 'dev.ananace.ruby-sdk.TestEvent' do
      bot.send :test_state_event
    end
  end

  def setup
    ::Net::HTTP.any_instance.expects(:request).never

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

    @bot = ExampleBot.new @client

    matrixsdk_add_api_stub
  end

  def test_configuration
    assert_predicate ExampleBot, :testing?
    assert ExampleBot.command? 'help'
    assert_not ExampleBot.command? 'help', ignore_inherited: true
    assert ExampleBot.command? 'test'
    assert ExampleBot.command? 'test_arr'

    # Check sane default configuration
    assert_predicate ExampleBot, :accept_invites?
    assert_predicate ExampleBot, :ignore_own?
    assert_not ExampleBot.require_fullname?
    assert_not ExampleBot.store_sync_token?
    assert_predicate ExampleBot, :threadsafe?
    assert_not ExampleBot.login?
    assert_not ExampleBot.logging?

    # Check generated configuration
    assert_predicate ExampleBot, :bot_name?
    # Bot name varies between 'rake_test_loader', 'bot_test', and 'rails' depending on how test is run
    assert_includes %w[rake_test_loader bot_test rails], ExampleBot.bot_name

    handlers = ExampleBot.instance_variable_get :@handlers

    assert_equal '_ARG [_ARG2]', handlers['test'].data[:args]
    assert_equal '[_ARGS...]', handlers['test_arr'].data[:args]
    assert_equal '', handlers['test_only'].data[:args]
  end

  def test_handling
    @room.stubs(:dm?).returns(false)

    ev = {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!not_a_command'
      }
    }

    assert_not @bot.command_allowed? 'not_a_command', ev
    @bot.send :_handle_event, ev

    ev = {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test_andmore'
      }
    }

    assert_not @bot.command_allowed? 'test_andmore', ev
    @bot.send :_handle_event, ev

    @bot.expects(:test_executed).once
    @bot.expects(:test_arr_executed).never

    ev = {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test'
      }
    }

    assert @bot.command_allowed? 'test', ev
    @bot.send :_handle_event, ev

    @bot.expects(:test_executed).never
    @bot.expects(:test_arr_executed).once

    ev = {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test_arr'
      }
    }

    assert @bot.command_allowed? 'test_arr', ev
    @bot.send :_handle_event, ev

    ev = {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test_only'
      }
    }

    @bot.expects(:test_only).never

    assert_not @bot.command_allowed? 'test_only', ev
    @bot.send :_handle_event, ev

    @room.stubs(:dm?).returns(true)

    @bot.expects(:test_only).once

    assert @bot.command_allowed? 'test_only', ev
    @bot.send :_handle_event, ev

    ev = {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test_only_proc'
      }
    }

    @room.stubs(:user_can_send?).with('@alice:example.com', 'm.reaction').returns(false)
    @bot.expects(:test_only_proc).never

    assert_not @bot.command_allowed? 'test_only_proc', ev
    @bot.send :_handle_event, ev

    @room.stubs(:user_can_send?).with('@alice:example.com', 'm.reaction').returns(true)

    @bot.expects(:test_only_proc).once

    assert @bot.command_allowed? 'test_only_proc', ev
    @bot.send :_handle_event, ev

    @room.stubs(:dm?).returns(false)

    @bot.expects(:test_executed).never

    ev = {
      type: 'm.room.message',
      sender: '@alice:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test'
      }
    }

    assert @bot.command_allowed? 'test', ev
    @bot.send :_handle_event, ev

    @bot.class.stubs(:ignore_own?).returns(false)

    @bot.expects(:test_executed).once

    assert @bot.command_allowed? 'test', ev
    @bot.send :_handle_event, ev

    @bot.expects(:test_event).with('$someevent').once

    ev = {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      event_id: '$someevent',
      content: {
        msgtype: 'm.text',
        body: '!test_event'
      }
    }

    assert @bot.command_allowed? 'test_event', ev
    @bot.send :_handle_event, ev

    @bot.expects(:test_state_event).once

    ev = {
      type: 'dev.ananace.ruby-sdk.TestEvent',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        hello: 'world'
      }
    }

    assert @bot.event_allowed? ev
    @bot.send :_handle_event, ev
  end

  def test_builtin_help
    @room.stubs(:dm?).returns(false)
    @room.stubs(:user_can_send?).returns(false)

    bot_name = ExampleBot.bot_name
    @room.expects(:send_notice).with(<<~MSG.strip)
      Usage:

      !help [COMMAND] - Shows this help text
      !#{bot_name} test _ARG [_ARG2]
      !#{bot_name} test_arr [_ARGS...]
      !#{bot_name} test_event
    MSG

    @bot.send :_handle_event, {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help'
      }
    }

    @room.expects(:send_notice).with(<<~MSG.strip)
      Help for help;
      !help [COMMAND] - Shows this help text
        For commands that take multiple arguments, you will need to use quotes around spaces
        E.g. !login "my username" "this is not a real password"
    MSG

    @bot.send :_handle_event, {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help help'
      }
    }

    @room.stubs(:dm?).returns(true)
    @room.stubs(:user_can_send?).returns(true)

    @room.expects(:send_notice).with(<<~MSG.strip)
      Usage:

      !help [COMMAND] - Shows this help text
      !test _ARG [_ARG2]
      !test_arr [_ARGS...]
      !test_only
      !test_event
      !test_only_proc
    MSG

    @bot.send :_handle_event, {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help'
      }
    }

    @room.expects(:send_notice).with(<<~MSG.strip)
      Help for help;
      !help [COMMAND] - Shows this help text
        For commands that take multiple arguments, you will need to use quotes around spaces
        E.g. !login "my username" "this is not a real password"
    MSG

    @bot.send :_handle_event, {
      type: 'm.room.message',
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help help'
      }
    }
  end
end
