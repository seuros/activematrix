# frozen_string_literal: true

module ActiveMatrix
  # Builders for event content, as the Matrix spec shapes it.
  #
  # Messages always carry `m.mentions` (empty when nobody is mentioned), so
  # clients ping exactly who the bot means to and not whoever its text
  # happens to name. Replies carry no fallback body: Matrix 1.13 retired it.
  module Content
    HTML = 'org.matrix.custom.html'

    module_function

    def text(body, html: nil, mentions: []) = message('m.text', body, html:, mentions:)
    def notice(body, html: nil, mentions: []) = message('m.notice', body, html:, mentions:)
    def emote(body, html: nil, mentions: []) = message('m.emote', body, html:, mentions:)

    def message(msgtype, body, html: nil, mentions: [])
      content = { 'msgtype' => msgtype, 'body' => body.to_s, 'm.mentions' => mention_block(mentions) }
      return content unless html

      content['format'] = HTML
      content['formatted_body'] = html
      content
    end

    # `content` as a reply to `event_id`.
    def reply(event_id, content)
      content.merge('m.relates_to' => { 'm.in_reply_to' => { 'event_id' => event_id } })
    end

    # `content` in the thread rooted at `root_event_id`. `in_reply_to` is the
    # latest event the bot answers, so clients without threads still show a
    # reply to it.
    def thread(root_event_id, content, in_reply_to: root_event_id)
      content.merge(
        'm.relates_to' => {
          'rel_type' => 'm.thread', 'event_id' => root_event_id,
          'is_falling_back' => true, 'm.in_reply_to' => { 'event_id' => in_reply_to }
        }
      )
    end

    # Content of an `m.reaction` event.
    def reaction(event_id, key)
      { 'm.relates_to' => { 'rel_type' => 'm.annotation', 'event_id' => event_id, 'key' => key } }
    end

    # Replaces `event_id`'s content with `new_content`.
    def edit(event_id, new_content)
      new_content.merge(
        'body' => "* #{new_content['body']}",
        'm.new_content' => new_content,
        'm.relates_to' => { 'rel_type' => 'm.replace', 'event_id' => event_id }
      )
    end

    # `room: true` mentions the whole room (`@room`).
    def mention_block(user_ids, room: false)
      block = { 'user_ids' => Array(user_ids).map(&:to_s).uniq }
      block['room'] = true if room
      block
    end
  end
end
