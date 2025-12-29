# frozen_string_literal: true

require 'test_helper'

class CommandParserTest < ActiveSupport::TestCase
  test 'recognizes command with ! prefix' do
    parser = ActiveMatrix::Bot::CommandParser.new('!help')

    assert parser.command?
    assert_equal 'help', parser.command_name
    assert_equal '!', parser.prefix
  end

  test 'recognizes command with / prefix' do
    parser = ActiveMatrix::Bot::CommandParser.new('/ping')

    assert parser.command?
    assert_equal 'ping', parser.command_name
    assert_equal '/', parser.prefix
  end

  test 'does not recognize non-command messages' do
    parser = ActiveMatrix::Bot::CommandParser.new('hello world')

    refute parser.command?
    assert_nil parser.command_name
  end

  test 'parses simple arguments' do
    parser = ActiveMatrix::Bot::CommandParser.new('!search foo bar')

    assert_equal 'search', parser.command_name
    assert_equal ['foo', 'bar'], parser.args
    assert_equal 'foo bar', parser.raw_args
  end

  test 'parses quoted arguments' do
    parser = ActiveMatrix::Bot::CommandParser.new('!search "hello world" test')

    assert_equal ['hello world', 'test'], parser.args
  end

  test 'parses single-quoted arguments' do
    parser = ActiveMatrix::Bot::CommandParser.new("!search 'hello world' test")

    assert_equal ['hello world', 'test'], parser.args
  end

  test 'parses flags with --key=value format' do
    parser = ActiveMatrix::Bot::CommandParser.new('!greet --name=Alice --formal')

    flags = parser.flags

    assert_equal 'Alice', flags['name']
    assert_equal true, flags['formal']
  end

  test 'parses short flags' do
    parser = ActiveMatrix::Bot::CommandParser.new('!test -v -abc')

    flags = parser.flags

    assert_equal true, flags['v']
    assert_equal true, flags['a']
    assert_equal true, flags['b']
    assert_equal true, flags['c']
  end

  test 'separates positional args from flags' do
    parser = ActiveMatrix::Bot::CommandParser.new('!cmd arg1 --flag arg2 --key=val')

    assert_equal ['arg1', 'arg2'], parser.positional_args
    assert_equal({ 'flag' => true, 'key' => 'val' }, parser.flags)
  end

  test 'flag? checks for flag presence' do
    parser = ActiveMatrix::Bot::CommandParser.new('!test --verbose')

    assert parser.flag?('verbose')
    refute parser.flag?('quiet')
  end

  test 'flag returns value or default' do
    parser = ActiveMatrix::Bot::CommandParser.new('!test --count=5')

    assert_equal '5', parser.flag('count')
    assert_equal 'default', parser.flag('missing', 'default')
  end

  test 'formatted_command returns full command string' do
    parser = ActiveMatrix::Bot::CommandParser.new('!help search')

    assert_equal 'help search', parser.formatted_command
  end

  test 'handles empty input' do
    parser = ActiveMatrix::Bot::CommandParser.new('')

    refute parser.command?
    assert_empty parser.args
  end

  test 'handles prefix-only input' do
    parser = ActiveMatrix::Bot::CommandParser.new('!')

    refute parser.command?
    assert_nil parser.command_name
  end

  test 'command name is lowercased' do
    parser = ActiveMatrix::Bot::CommandParser.new('!HELP')

    assert_equal 'help', parser.command_name
  end

  test 'custom prefixes can be specified' do
    parser = ActiveMatrix::Bot::CommandParser.new('.help', prefixes: ['.'])

    assert parser.command?
    assert_equal 'help', parser.command_name
    assert_equal '.', parser.prefix
  end

  test 'handles mixed quotes in arguments' do
    parser = ActiveMatrix::Bot::CommandParser.new('!cmd "he said \'hello\'" test')

    # Inner quotes are preserved
    assert_equal ["he said 'hello'", 'test'], parser.args
  end
end
