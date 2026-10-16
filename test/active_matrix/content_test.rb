# frozen_string_literal: true

require 'test_helper'

class ContentTest < ActiveSupport::TestCase
  C = ActiveMatrix::Content

  test 'messages carry m.mentions and optional HTML' do
    assert_equal({ 'msgtype' => 'm.text', 'body' => 'hi', 'm.mentions' => { 'user_ids' => ['@a:m'] } },
                 C.text('hi', mentions: ['@a:m']))
    assert_equal({ 'msgtype' => 'm.notice', 'body' => 'b', 'm.mentions' => { 'user_ids' => [] },
                   'format' => 'org.matrix.custom.html', 'formatted_body' => '<b>b</b>' },
                 C.notice('b', html: '<b>b</b>'))
  end

  test 'relations' do
    assert_equal({ 'm.in_reply_to' => { 'event_id' => '$1' } }, C.reply('$1', {})['m.relates_to'])
    assert_equal({ 'rel_type' => 'm.annotation', 'event_id' => '$1', 'key' => '👍' },
                 C.reaction('$1', '👍')['m.relates_to'])
    edit = C.edit('$1', C.text('fixed'))

    assert_equal ['* fixed', 'fixed', { 'rel_type' => 'm.replace', 'event_id' => '$1' }],
                 [edit['body'], edit.dig('m.new_content', 'body'), edit['m.relates_to']]
  end

  test 'mentioning the room' do
    assert_equal({ 'user_ids' => [], 'room' => true }, C.mention_block([], room: true))
  end
end
