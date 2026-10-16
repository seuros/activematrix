# frozen_string_literal: true

# System tests: the real activematrixd, the dummy app over HTTP, and a
# homeserver: activematrix-fakehs, or Synapse for the contract tier
# (ACTIVEMATRIX_SYNAPSE_URL). `bundle exec rake test:system` builds the
# binaries and runs them; `rake test` leaves them out.
ENV['ACTIVEMATRIX_TEST_DATABASE'] ||= 'activematrix_system'
require_relative '../test_helper'
Dir[File.expand_path('support/*.rb', __dir__)].each { require it }

module SystemTests
  module_function

  def homeserver
    url = ENV.fetch('ACTIVEMATRIX_SYNAPSE_URL', nil)
    return FakeHomeserver.start unless url

    Synapse.new(url, ENV.fetch('ACTIVEMATRIX_SYNAPSE_SECRET'))
  end
end

class SystemTestCase < ActiveSupport::TestCase
  # The daemon is another process: it only sees committed rows.
  self.use_transactional_tests = false

  SECRET = 'system-tests-delivery-secret-0123456789'
  SHUTDOWN_TIMEOUT = 5

  setup do
    @dir = Dir.mktmpdir('activematrix-system')
    @daemons = []
    @homeserver = SystemTests.homeserver
    @rails = SystemTests::RailsServer.start(Rails.application)
    ActiveMatrix.config.delivery_secret = SECRET
    # Jobs run as under a real backend, on threads of their own. The cell is
    # a fork, so nothing needs restoring.
    ActiveJob::Base.queue_adapter = :async
    # The test runs inside the executor, whose query cache would answer every
    # poll of a row the daemon or a job is changing with the first result.
    ActiveRecord::Base.connection_pool.disable_query_cache!
    # ACTIVEMATRIX_SYSTEM_LOG=1 shows the app's log (requests, jobs) on stderr.
    if ENV['ACTIVEMATRIX_SYSTEM_LOG']
      Rails.logger = ActiveJob::Base.logger = ActionController::Base.logger = ActiveSupport::Logger.new($stderr)
    end
    @master_key = [SecureRandom.random_bytes(32)].pack('m0')
  end

  teardown do
    @daemons.each(&:kill)
    print_daemon_logs unless passed?
    @rails&.stop
    @homeserver&.stop
    truncate_tables
    FileUtils.rm_rf(@dir)
  end

  private

  # A bot account with an agent running EchoBot, a daemon running it, and
  # a room Alice invited it to. Most tests start here.
  def boot_bot
    @alice = @homeserver.register(unique('alice'))
    @bot = @homeserver.register(unique('bot'))
    @agent = agent_for(@bot)
    @daemon = start_daemon
    wait_online(@agent)
    @room = open_room(@alice, @bot)
  end

  # An agent for the account, logged in the way an operator does it:
  # `activematrix login NAME --token-stdin`.
  def agent_for(user)
    agent = ActiveMatrix::Agent.create!(name: user.user_id[/\A@([^:]+)/, 1], bot_class: 'EchoBot',
                                        homeserver_url: @homeserver.url)
    daemon.run!('login', agent.name, '--token-stdin', stdin: user.access_token)
    agent.reload
  end

  def daemon = SystemTests::DaemonProcess.new(daemon_env, @dir).tap { @daemons << it }
  def start_daemon = daemon.start

  def daemon_env
    {
      'ACTIVEMATRIX_DATABASE_URL' => database_url,
      'ACTIVEMATRIX_MASTER_KEY' => @master_key,
      'ACTIVEMATRIX_DELIVERY_URL' => @rails.url('/active_matrix/deliveries'),
      'ACTIVEMATRIX_DELIVERY_SECRET' => SECRET,
      'ACTIVEMATRIX_PROBE_BIND' => '127.0.0.1:0',
      'ACTIVEMATRIX_NODE_ID' => unique('node'),
      'ACTIVEMATRIX_HEARTBEAT_SECS' => '1',
      'ACTIVEMATRIX_LEASE_TTL_SECS' => '3',
      'ACTIVEMATRIX_SHUTDOWN_TIMEOUT_SECS' => SHUTDOWN_TIMEOUT.to_s,
      'ACTIVEMATRIX_CONFIG' => nil,
      'DATABASE_URL' => nil,
      'RUST_LOG' => ENV.fetch('RUST_LOG', 'info')
    }
  end

  # This worker's database, for the daemon.
  def database_url
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    URI::Generic.build(scheme: 'postgresql', userinfo: "#{config[:username]}:#{config[:password]}",
                       host: config[:host], port: config[:port], path: "/#{config[:database]}").to_s
  end

  # `owner` invites `bot` to a new room; returns once the bot has joined.
  def open_room(owner, bot)
    room_id = @homeserver.room(owner, bot)
    eventually("#{bot.user_id} to join #{room_id}") { @homeserver.joined?(bot, room_id) }
    room_id
  end

  def say(body, from: @alice, room: @room, to: @bot) = @homeserver.say(from, room, body, to:)

  # What the bot sent to the room, optionally only messages saying `body`.
  def replies(body = nil, room: @room, sender: @bot)
    messages = @homeserver.messages(room, sender:)
    body ? messages.select { it == body } : messages
  end

  def wait_for_replies(body, count, room: @room, sender: @bot)
    eventually("#{count} #{body.inspect} from #{sender.user_id}") do
      replies(body, room:, sender:).size >= count
    end
    replies(body, room:, sender:)
  end

  def wait_online(*agents)
    agents.each { |agent| eventually("#{agent.name} to be online") { agent.reload.online? } }
  end

  def eventually(what, timeout: 20)
    deadline = monotonic + timeout
    until (result = yield)
      flunk "timed out after #{timeout}s waiting for #{what}" if monotonic > deadline
      sleep 0.05
    end
    result
  end

  # Asserts the block stays true for `seconds`.
  def consistently(what, seconds:)
    deadline = monotonic + seconds
    while monotonic < deadline
      assert yield, "expected #{what}"
      sleep 0.1
    end
  end

  # For behaviour only the fake can provoke (fault injection).
  def fake_only!
    skip 'needs activematrix-fakehs (fault injection)' unless @homeserver.fake?
  end

  def unique(name) = "#{name}-#{SecureRandom.hex(3)}"
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def truncate_tables
    connection = ActiveRecord::Base.connection
    tables = connection.tables.grep(/\Aactive_matrix_/).map { connection.quote_table_name(it) }
    connection.execute("TRUNCATE #{tables.join(', ')} CASCADE") if tables.any?
  end

  def print_daemon_logs
    @daemons.map(&:log).select { File.exist?(it) }.each do |log|
      warn "--- #{File.basename(log)} (last 80 lines)", File.readlines(log).last(80).join
    end
    warn '--- agents, inbox, outbox'
    ActiveMatrix::Agent.find_each { warn it.attributes.except('access_token_ciphertext').inspect }
    ActiveMatrix::InboxEvent.order(:id).each { warn it.attributes.except('raw').inspect }
    ActiveMatrix::OutboxCommand.order(:id).each { warn it.attributes.inspect }
  end
end
