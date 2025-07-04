# ActiveMatrix

A Rails-native Matrix SDK for building multi-agent bot systems and real-time communication features. This gem is a fork of the [matrix-sdk](https://github.com/ananace/ruby-matrix-sdk) gem, extensively enhanced with Rails integration, multi-agent architecture, and persistent state management.

## Features

- **Multi-Agent Architecture**: Run multiple bots concurrently with lifecycle management
- **Rails Integration**: Deep integration with ActiveRecord, Rails.cache, and Rails.logger
- **State Machines**: state_machines-powered state management for bot lifecycle
- **Memory System**: Three-tier memory architecture (agent, conversation, global)
- **Event Routing**: Intelligent event distribution to appropriate agents
- **Client Pooling**: Efficient connection management for multiple bots
- **Generators**: Rails generators for quick bot creation
- **Inter-Agent Communication**: Built-in messaging between bots

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'activematrix', '~> 0.0.3'
```

And then execute:

```bash
$ bundle install
$ rails generate active_matrix:install
$ rails db:migrate
```

## Multi-Agent System Usage

### Creating Your First Bot

```bash
$ rails generate active_matrix:bot captain
```

This creates a bot class in `app/bots/captain_bot.rb`:

```ruby
class CaptainBot < ActiveMatrix::Bot::MultiInstanceBase
  set :accept_invites, true
  set :command_prefix, '!'
  
  command :status,
          desc: 'Get system status',
          args: '[component]' do |component = nil|
    if component
      # Check specific component
      status = memory.get("status_#{component}") || 'unknown'
      room.send_notice("#{component}: #{status}")
    else
      # Overall status
      room.send_notice("All systems operational!")
    end
  end
  
  command :deploy,
          desc: 'Deploy to production',
          args: 'target' do |target|
    # Use conversation memory to track deployments
    deployments = conversation_memory.remember(:deployments) { [] }
    deployments << { target: target, time: Time.current }
    conversation_memory[:deployments] = deployments
    
    # Notify other agents
    broadcast_to_agents(:lieutenant, {
      type: 'deployment',
      target: target,
      initiated_by: agent_name
    })
    
    room.send_notice("Deploying to #{target}...")
  end
  
  # Handle inter-agent messages
  def receive_message(data, from:)
    case data[:type]
    when 'status_report'
      memory.set("status_#{data[:component]}", data[:status])
      logger.info "Received status update from #{from.agent_name}"
    end
  end
end
```

### Setting Up Agents

```ruby
# Create agent records in Rails console or seeds
captain = MatrixAgent.create!(
  name: 'captain',
  homeserver: 'https://matrix.org',
  username: 'captain_bot',
  password: 'secure_password',
  bot_class: 'CaptainBot',
  settings: {
    rooms_to_join: ['!warroom:matrix.org'],
    command_prefix: '!'
  }
)

lieutenant = MatrixAgent.create!(
  name: 'lieutenant', 
  homeserver: 'https://matrix.org',
  username: 'lieutenant_bot',
  password: 'secure_password',
  bot_class: 'LieutenantBot'
)
```

### Managing Agents

```ruby
# Start all agents
ActiveMatrix::AgentManager.instance.start_all

# Start specific agent
ActiveMatrix::AgentManager.instance.start_agent(captain)

# Check status
ActiveMatrix::AgentManager.instance.status
# => { running: 2, agents: [...], monitor_active: true }

# Stop agent
ActiveMatrix::AgentManager.instance.stop_agent(captain)

# Restart agent
ActiveMatrix::AgentManager.instance.restart_agent(captain)
```

## Memory System

### Agent Memory (Private)
```ruby
# In your bot
memory.set('last_deployment', Time.current)
memory.get('last_deployment')
memory.increment('deployment_count')
memory.remember('config') { load_config_from_api }
```

### Conversation Memory (Per User/Room)
```ruby
# Automatically available in commands
conversation_memory[:last_command] = 'deploy'
context = conversation_context # Hash of conversation data

# Track message history
conversation_memory.add_message(event)
recent = conversation_memory.recent_messages(5)
```

### Global Memory (Shared)
```ruby
# Set global data
global_memory.set('system_status', 'operational', 
  category: 'monitoring',
  expires_in: 5.minutes,
  public_read: true
)

# Broadcast to all agents
global_memory.broadcast('alert', {
  level: 'warning',
  message: 'High CPU usage detected'
})

# Share between specific agents
global_memory.share('secret_key', 'value', ['captain', 'lieutenant'])
```

## Event Routing

```ruby
class MonitorBot < ActiveMatrix::Bot::MultiInstanceBase
  # Route specific events to this bot
  route event_type: 'm.room.message', priority: 100 do |bot, event|
    # Custom processing
  end
  
  route room_id: '!monitoring:matrix.org' do |bot, event|
    # Handle all events from monitoring room
  end
end
```

## Basic Client Usage

For simple, single-bot applications:

```ruby
# Traditional client usage still works
client = ActiveMatrix::Client.new 'https://matrix.org'
client.login 'username', 'password'

room = client.find_room '#matrix:matrix.org'
room.send_text "Hello from ActiveMatrix!"
```

## Configuration

```ruby
# config/initializers/active_matrix.rb
ActiveMatrix.configure do |config|
  config.agent_startup_delay = 2.seconds
  config.max_agents_per_process = 10
  config.agent_health_check_interval = 30.seconds
  config.conversation_history_limit = 20
  config.conversation_stale_after = 1.day
  config.memory_cleanup_interval = 1.hour
end
```

## Testing

```ruby
# spec/bots/captain_bot_spec.rb
RSpec.describe CaptainBot do
  let(:agent) { create(:matrix_agent, bot_class: 'CaptainBot') }
  let(:bot) { described_class.new(agent) }
  
  it 'responds to status command' do
    expect(room).to receive(:send_notice).with(/operational/)
    bot.status
  end
end
```

## Architecture

ActiveMatrix implements a sophisticated multi-agent architecture:

- **AgentManager**: Manages lifecycle of all bots (start/stop/restart)
- **AgentRegistry**: Thread-safe registry of running bot instances  
- **EventRouter**: Routes Matrix events to appropriate bots
- **ClientPool**: Manages shared client connections efficiently
- **Memory System**: Hierarchical storage with caching
- **State Machines**: Track agent states (offline/connecting/online/busy/error)

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/seuros/agent_smith

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).