# ActiveMatrix

A Rails-native Matrix SDK for building multi-agent bot systems and real-time communication features. This gem is a fork of the [matrix-sdk](https://github.com/ananace/ruby-matrix-sdk) gem, extensively enhanced with Rails integration, multi-agent architecture, and persistent state management.

## Requirements

- **Ruby 3.4+**
- **Rails 8.0+**
- **PostgreSQL 18+** (required for UUIDv7 primary keys)

## Features

- **Multi-Agent Architecture**: Run multiple bots concurrently with async fiber-based lifecycle management
- **Daemon Binary**: Production-ready `activematrix` daemon with multi-process workers and health probes
- **Rails Integration**: Deep integration with ActiveRecord, Rails.cache, and Rails.logger
- **State Machines**: state_machines-powered state management for bot lifecycle
- **Memory System**: Three-tier memory architecture (agent, conversation, global)
- **Event Routing**: Intelligent event distribution to appropriate agents
- **Client Pooling**: Efficient connection management with async semaphores
- **Generators**: Rails generators for quick bot creation
- **Inter-Agent Communication**: Built-in messaging between bots
- **PostgreSQL 18 Features**: UUIDv7 primary keys, JSONB with GIN indexes

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'activematrix'
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
captain = ActiveMatrix::Agent.create!(
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

lieutenant = ActiveMatrix::Agent.create!(
  name: 'lieutenant',
  homeserver: 'https://matrix.org',
  username: 'lieutenant_bot',
  password: 'secure_password',
  bot_class: 'LieutenantBot'
)
```

### Running the Daemon

The `activematrix` binary manages your bots in production, similar to Sidekiq or GoodJob:

```bash
# Start in foreground
bundle exec activematrix start

# Start with multiple worker processes
bundle exec activematrix start --workers 3

# Start specific agents only
bundle exec activematrix start --agents captain,lieutenant

# Daemonize with PID file
bundle exec activematrix start --daemon --pidfile tmp/pids/activematrix.pid

# Check status (queries health probe)
bundle exec activematrix status

# Graceful shutdown
bundle exec activematrix stop

# Reload agent configuration
bundle exec activematrix reload
```

**Health Probes** (for Kubernetes/Docker):
- `GET /health` - Returns 200 if healthy
- `GET /status` - JSON with detailed agent status
- `GET /metrics` - Prometheus-compatible metrics

```bash
curl http://localhost:3042/health
curl http://localhost:3042/status
```

### Programmatic Agent Management

```ruby
# Start all agents (blocks until shutdown)
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
  # Agent settings
  config.agent_startup_delay = 2.seconds
  config.max_agents_per_process = 10
  config.agent_health_check_interval = 30.seconds

  # Memory settings
  config.conversation_history_limit = 20
  config.conversation_stale_after = 1.day
  config.memory_cleanup_interval = 1.hour

  # Daemon settings
  config.daemon_workers = 2
  config.probe_port = 3042
  config.probe_host = '0.0.0.0'
  config.shutdown_timeout = 30
end
```

## Testing

```ruby
# test/bots/captain_bot_test.rb
class CaptainBotTest < ActiveSupport::TestCase
  def setup
    @agent = ActiveMatrix::Agent.create!(
      name: 'test_captain',
      homeserver: 'https://matrix.org',
      username: 'test_bot',
      bot_class: 'CaptainBot'
    )
  end

  test 'responds to status command' do
    # Your test logic here
  end
end
```

## Architecture

ActiveMatrix implements a sophisticated multi-agent architecture:

- **AgentManager**: Manages lifecycle of all bots using async fibers (start/stop/restart)
- **AgentRegistry**: Fiber-safe registry of running bot instances
- **EventRouter**: Routes Matrix events to appropriate bots via async queues
- **ClientPool**: Manages shared client connections with async semaphores
- **Memory System**: Hierarchical storage with caching
- **State Machines**: Track agent states (offline/connecting/online/busy/error)

### Models

All models are namespaced under `ActiveMatrix::`:

- `ActiveMatrix::Agent` - Bot agent records with state machine
- `ActiveMatrix::AgentStore` - Per-agent key-value storage
- `ActiveMatrix::ChatSession` - Conversation context per user/room
- `ActiveMatrix::KnowledgeBase` - Global shared storage

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/seuros/activematrix

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).