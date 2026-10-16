# frozen_string_literal: true

require 'test_helper'

class CommandParserTest < ActiveSupport::TestCase
  def parse(text, **) = ActiveMatrix::Bot::CommandParser.parse(text, **)

  test 'a command is a prefix, a name and its arguments' do
    command = parse('!Deploy api eu')

    assert_equal ['!', 'deploy', %w[api eu], {}, 'api eu'], command.to_h.values_at(:prefix, :name, :args, :flags, :rest)
  end

  test 'quotes group words only when they open an argument' do
    assert_equal ['release notes', 'x'], parse('!say "release notes" x').args
    assert_equal %w[don't stop], parse("!say don't stop").args
    assert_equal ["it's done"], parse(%(!say "it's done")).args
  end

  test 'flags take values, dashes become underscores, and -- ends them' do
    command = parse('!deploy api --force --region=eu --dry-run -- --not-a-flag')

    assert_equal %w[api --not-a-flag], command.args
    assert_equal({ 'force' => true, 'region' => 'eu', 'dry_run' => true }, command.flags)
  end

  test 'rest keeps the text as typed' do
    assert_equal 'hello   wide  world', parse('!echo   hello   wide  world').rest
  end

  test 'not commands' do
    ['hello', '! deploy', '!', '', nil, 'say !deploy', '!dep/loy'].each do |text|
      assert_nil parse(text), text.inspect
    end
  end

  test 'prefixes are configurable' do
    assert_equal 'ping', parse('/ping', prefixes: ['/', '!']).name
    assert_nil parse('/ping')
  end
end
