# frozen_string_literal: true

# The bot the engine's own tests drive.
class EchoBot < ApplicationBot
  setting :greeting, :string, default: 'Welcome'
  setting :shout, :boolean, default: false

  rescue_from ArgumentError do |error|
    reply "Sorry: #{error.message}", notice: true
  end

  before_command :require_known_sender, only: :secret

  command :ping, 'Answer pong' do
    reply 'pong'
  end

  command :echo, 'Repeat the text', raw: true do |text|
    reply settings.shout ? text.upcase : text
  end

  command :deploy, 'Deploy a target', power: :moderator do |target, region = 'eu', force: false|
    reply "Deploying #{target} to #{region}#{' (forced)' if force}", thread: true
  end

  command :remember, 'Remember a value' do |key, value|
    memory[key] = value
    conversation[:last_key] = key
    reply "Remembered #{key}"
  end

  command :count, 'Count calls' do
    reply "Count: #{memory.increment(:count)}"
  end

  command :fail, 'Raise an error' do
    raise ArgumentError, 'that went wrong'
  end

  command :explode, 'Raise an unhandled error' do
    reply 'this reply must never be sent'
    raise 'boom'
  end

  command :secret, 'Only for known senders' do
    reply 'the secret'
  end

  command :handoff, 'Hand work to another agent' do |name|
    deliver_to name, 'work', { 'from' => sender }
    reply "Handed to #{name}"
  end

  on 'm.room.member', if: -> { content['membership'] == 'join' && sender != me } do
    reply "#{settings.greeting}, #{sender}!"
  end

  on 'm.reaction' do
    react '👀', to: content.dig('m.relates_to', 'event_id')
  end

  on_invite { join }

  on_agent_message 'work' do |payload|
    memory[:work_from] = payload['from']
  end

  private

  def require_known_sender
    return if sender == '@alice:matrix.test'

    reply 'Not you.', notice: true
    halt!
  end
end
