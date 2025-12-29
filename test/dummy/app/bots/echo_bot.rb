# frozen_string_literal: true

# Simple test bot that echoes messages
class EchoBot < ActiveMatrix::Bot::MultiInstanceBase
  set :accept_invites, true
  set :command_prefix, '!'

  command :echo,
          desc: 'Echo back the message',
          args: 'message' do |*args|
    message = args.join(' ')
    room.send_text("Echo: #{message}")
  end

  command :ping,
          desc: 'Respond with pong' do
    room.send_text('Pong!')
  end

  command :status,
          desc: 'Show bot status' do
    room.send_notice("Agent: #{agent_name}\nUptime: #{uptime}\nMessages handled: #{agent_record.messages_handled}")
  end

  def uptime
    started = agent_record.last_active_at || Time.current
    seconds = (Time.current - started).to_i
    "#{seconds / 3600}h #{(seconds % 3600) / 60}m #{seconds % 60}s"
  end
end
