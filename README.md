# ActiveMatrix

Matrix bots for Rails. Bots are Ruby classes that run as Active Job jobs;
`activematrixd`, a daemon written in Rust and shipped inside the gem, holds
every Matrix connection.

> **Status:** this is the 0.1 design, in development on `master`. The 0.0.x
> releases on RubyGems are the previous, in-process design and are not
> compatible with it.

## Requirements

- **Ruby 4.0** or newer
- **Rails 8.1** or newer
- **PostgreSQL 18** or newer

Nothing older is supported. Platform gems carry the daemon prebuilt for
Linux (glibc and musl) and macOS once 0.1 is released; until then, or on
another platform, build it with Cargo (see [Development](#development)).

## How it works

```
Matrix ⇄ activematrixd ─── writes ──▶ PostgreSQL ◀── reads ─── Rails (your bots)
           syncs agents      rooms, members, state, inbox
           sends the outbox  ◀── outbox ──────────────────── replies, commands
           pushes "new events in room X" ─▶ POST /active_matrix/deliveries ─▶ jobs
```

- The daemon syncs every agent, mirrors room state into tables your app can
  query, and queues new events in an **inbox**.
- It tells Rails which rooms have new events. Rails enqueues a job per room;
  the job runs your bot on each event, oldest first, **exactly once**: the
  event is marked handled in the same transaction as everything the
  handler writes.
- What a bot sends goes to an **outbox** in that transaction. The daemon
  sends it after the commit and never if the handler fails. The outbox row's
  id is the Matrix transaction id, so a retried send cannot post twice.
- Access tokens are sealed with a key only the daemon holds. Rails never sees
  them.

## Installation

```ruby
# Gemfile
gem 'activematrix'
```

```console
$ bundle install
$ bin/rails generate active_matrix:install
$ bin/rails db:migrate
```

The generator copies the migrations, mounts the engine at `/active_matrix`,
and writes `config/initializers/active_matrix.rb`, `app/bots/application_bot.rb`
and `config/activematrixd.toml`.

Two secrets, from the environment:

```console
$ export ACTIVEMATRIX_MASTER_KEY=$(bundle exec activematrix keygen)   # the daemon only
$ export ACTIVEMATRIX_DELIVERY_SECRET=$(openssl rand -hex 32)         # the daemon and Rails
```

The master key seals access tokens: keep it with your other secrets, since
losing it means logging every agent in again. The delivery secret signs the
daemon's requests to Rails; Rails reads it from
`config.delivery_secret` (credentials or `ACTIVEMATRIX_DELIVERY_SECRET`).

## A bot

```console
$ bin/rails generate active_matrix:bot captain status deploy
```

```ruby
# app/bots/captain_bot.rb
class CaptainBot < ApplicationBot
  setting :greeting, :string, default: 'Welcome aboard'

  # !status
  command :status, 'Show the status' do
    reply "All systems nominal. Deploys today: #{memory.fetch(:deploys, 0)}"
  end

  # !deploy api   !deploy api us --force
  command :deploy, 'Deploy a target', power: :moderator do |target, region = 'eu', force: false|
    memory.increment(:deploys)
    reply "Deploying #{target} to #{region}#{' (forced)' if force}", thread: true
  end

  # !say any text, exactly as typed
  command :say, 'Repeat the text', raw: true do |text|
    reply text
  end

  on 'm.room.member', if: -> { content['membership'] == 'join' && sender != me } do
    reply "#{settings.greeting}, #{sender}!", mentions: [sender]
  end

  on_invite { join }
end
```

### Commands

- Positional block parameters take the arguments; keyword parameters take
  `--flags`. Wrong arguments or an unknown flag answer with a usage line
  built from the block: `Usage: !deploy TARGET [REGION] [--force]`.
- Quotes group words: `!say "two words"`. `raw: true` passes the text after
  the command name as typed instead.
- `!help` lists the commands with their descriptions.
- Commands come from `m.text` messages; notices (what bots send each other)
  and edits are not commands. `prefix '!', '/'` changes the prefixes.

### Guards and callbacks

- `dm: true` (direct rooms only) or `dm: false` (group rooms only).
- `power: :moderator` (50), `:admin` (100) or a level, read from the room's
  power levels. Below it, the bot says which level is needed.
- `if: -> { ... }`, evaluated in the bot.
- `before_command :method, only: :deploy` runs first; `halt!` stops the command.
- `rescue_from SomeError, with: :method` (or a block) answers instead of
  failing.

### What a handler reads

| | |
|---|---|
| `event`, `content`, `body`, `sender`, `room_id` | the event |
| `room`, `direct?` | the mirrored room (`room.power_level(user)`, `room.state(type, key)`, `room.members`) |
| `me`, `agent` | the bot's own user id and agent record |
| `settings` | the agent's settings, typed by `setting` declarations |
| `memory`, `conversation`, `global` | memory for the agent, this user in this room, and every agent |

Memory takes any JSON value: `memory[:key] = value`, `memory.fetch(:key, default)`,
`memory.write(:key, value, expires_in: 1.hour)`, `memory.increment(:count)`
(atomic), `memory.delete(:key)`.

### What a handler does

All of these write to the outbox in the handler's transaction:

| | |
|---|---|
| `reply(text, html:, notice:, thread:, quote:, mentions:)` | send a message; `thread: true` answers in the event's thread |
| `react('👍')`, `edit(event_id, text)`, `redact(event_id, reason:)` | relations |
| `send_event(type, content)`, `set_state(type, content, state_key:)` | anything else |
| `join`, `leave`, `invite(user)`, `kick(user)`, `ban(user)`, `unban(user)` | membership |
| `typing`, `typing(on: false)`, `read_receipt` | presence in the room |
| `deliver_to(:other_agent, 'topic', payload)` | hand work to another agent's `on_agent_message('topic')` |

Messages always carry `m.mentions`, so clients notify exactly the users in
`mentions:` and not whoever the text happens to name.

Handlers run in your job backend; a handler that raises rolls back what it
wrote and is retried, then set aside after five failures so the room moves on.

## Agents

An agent is a Matrix account running a bot:

```ruby
ActiveMatrix::Agent.create!(name: 'captain', bot_class: 'CaptainBot',
                            homeserver_url: 'https://matrix.example.org',
                            settings: { 'greeting' => 'Ahoy' })
```

Log it in once; the daemon stores the access token sealed:

```console
$ bundle exec activematrix login captain                    # prompts for the password
$ bundle exec activematrix login captain --password-stdin
$ echo "$TOKEN" | bundle exec activematrix login captain --token-stdin
```

`agent.update!(enabled: false)` stops it within a heartbeat. The daemon owns
`state` (`offline`, `starting`, `online`, `reconnecting`, `failed`) and
`last_error`; an agent whose token the homeserver rejects is `failed` until
it logs in again. Every room the agent knows is mirrored in `agent.rooms`;
`membership` says whether it is joined, invited or gone.

## Running the daemon

```console
$ bundle exec activematrix check   # configuration, database and migrations
$ bundle exec activematrix start
```

Run it next to your web and job processes. It needs the same database as
Rails, the master key, and the delivery URL and secret. On `SIGTERM` it
drains: agents stop, their leases are released, and it exits; a second
signal exits at once.

### Scaling

Agents are leased: each daemon process claims up to `max_agents`, renews
their leases every heartbeat, and gives them back on shutdown. Run more
processes or replicas to run more agents; a daemon that dies loses its
agents to the others when the leases run out.

### Configuration

`config/activematrixd.toml`, each setting overridable by the variable next
to it. Secrets come from the environment only.

| Setting | Variable | Default |
|---|---|---|
| database | `ACTIVEMATRIX_DATABASE_URL`, else `DATABASE_URL` | required |
| master key | `ACTIVEMATRIX_MASTER_KEY` (and `ACTIVEMATRIX_MASTER_KEY_PREVIOUS` while rotating) | required |
| `delivery_url` | `ACTIVEMATRIX_DELIVERY_URL` | required |
| delivery secret | `ACTIVEMATRIX_DELIVERY_SECRET` | required, 32+ characters |
| `probe_bind` | `ACTIVEMATRIX_PROBE_BIND` | `127.0.0.1:3042` |
| `max_agents` | `ACTIVEMATRIX_MAX_AGENTS` | `100` |
| `heartbeat_secs` | `ACTIVEMATRIX_HEARTBEAT_SECS` | `10` |
| `lease_ttl_secs` | `ACTIVEMATRIX_LEASE_TTL_SECS` | `30` (at least 3 heartbeats) |
| `shutdown_timeout_secs` | `ACTIVEMATRIX_SHUTDOWN_TIMEOUT_SECS` | `30` |
| `node_id` | `ACTIVEMATRIX_NODE_ID` | `hostname:pid` |

`ACTIVEMATRIX_CONFIG` (or `--config`) points at another file; `RUST_LOG`
sets the log level. To rotate the master key, move the current one to
`ACTIVEMATRIX_MASTER_KEY_PREVIOUS` and set a new one: tokens are resealed as
agents start.

### Probes

Answered from memory, so a database outage does not restart the daemon:

- `GET /livez`: the daemon's heartbeat is running.
- `GET /readyz`: live and not draining (503 while draining).
- `GET /status`: JSON with every agent and its state.
- `GET /metrics`: Prometheus text.

Bind `probe_bind` to `0.0.0.0:3042` in containers.

### Housekeeping

Schedule `ActiveMatrix::MemoryReaperJob`, for example hourly in
`config/recurring.yml`. It deletes expired memories, and handled inbox events
and sent outbox commands older than `config.inbox_retention` (30 days) and
`config.outbox_retention` (7 days).

## Testing your bots

No daemon or homeserver needed: events go into the inbox the way the daemon
writes them, the job runs at once, and you assert on the outbox.

```ruby
require 'test_helper'
require 'active_matrix/testing'

class CaptainBotTest < ActiveSupport::TestCase
  include ActiveMatrix::Testing

  setup do
    @agent = ActiveMatrix::Agent.create!(name: 'captain', bot_class: 'CaptainBot',
                                         homeserver_url: 'https://matrix.test')
  end

  test 'say repeats the text' do
    deliver_message(@agent, '!say hello there')

    assert_replied @agent, 'hello there'
  end
end
```

`deliver_message`, `deliver_event` and `deliver_invite` put events in;
`replies`, `assert_replied`, `assert_no_replies` and `assert_outbox` read
what the bot queued.

## Upgrading from 0.0.x

The migrations upgrade the 0.0.x tables in place: agents keep their name,
bot class and settings, and agent stores, the knowledge base and chat context
move into memories. Access tokens do not carry over (0.0.x sealed them with
Active Record encryption, which the daemon cannot read), so run
`activematrix login` for each agent. The bot API is new: port bots to
`ActiveMatrix::Bot::Base`.

## Not yet

- **End-to-end encryption.** Agents cannot read or send in encrypted rooms.
- Application service (bridge) mode.

## Development

```console
$ mise install                    # Ruby 4.0 and Rust 1.99, from mise.toml
$ docker compose up -d            # PostgreSQL 18 on port 5440
$ bundle install
$ (cd test/dummy && RAILS_ENV=test bin/rails db:prepare)
$ bundle exec rake test           # the Ruby suite, under padded_cell
$ cargo test --workspace          # the daemon, against the same PostgreSQL
$ bundle exec rake test:system    # everything together, against a fake homeserver
$ dictator lint .                 # line and file length, layout, whitespace
$ cargo fmt --all && cargo clippy --all-targets
```

- Style is checked by [dictator](https://github.com/seuros/dictator)
  (`.dictate.toml`), rustfmt (`rustfmt.toml`) and clippy; there is no RuboCop.
- `test/system` runs the real daemon against the dummy app, served over HTTP
  by [shuttlebay](https://github.com/seuros/shuttlebay), and
  `activematrix-fakehs`. `rake test:system` builds both binaries first;
  `ACTIVEMATRIX_SYSTEM_LOG=1` prints the app's log, and a failing test prints
  the daemon's log and the agent, inbox and outbox rows.
- The same tests run against Synapse:
  `docker compose --profile contract up -d && bundle exec rake test:contract`.
  CI does it nightly (`contract.yml`); fault injection tests skip there.
- The daemon's tests load `crates/activematrixd/tests/schema.sql`, a
  snapshot of the engine's tables. After changing a migration, run
  `bundle exec rake active_matrix:schema_snapshot`; CI fails when it is stale.
- `crates/activematrix-fakehs` is a fake homeserver used by the daemon's
  tests; its binary has an admin API under `/_fake/` for tests in other
  languages.
- `bundle exec rake 'package[arm64-darwin]'` builds a platform gem with the
  daemon inside; `ACTIVEMATRIX_INSTALL_DIR` points the launcher at a local
  build instead.
- Releases: release-please opens the release PR; merging it tags the
  version, and `release.yml` builds the six platform gems (Linux gnu and
  musl, macOS, each on x86_64 and arm64) plus the platformless one, and
  attaches them to the GitHub Release. Running `release.yml` by hand builds
  and checks them without releasing.

## License

MIT. ActiveMatrix began as a fork of
[matrix-sdk](https://github.com/ananace/ruby-matrix-sdk) by Alexander
Olofsson.
