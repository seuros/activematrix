# frozen_string_literal: true

# ActiveMatrix configuration
ActiveMatrix.configure do |config|
  # Agent configuration
  config.agent_startup_delay = 2.seconds # Delay between starting each agent
  config.max_agents_per_process = 10     # Maximum agents in a single process
  config.agent_health_check_interval = 30.seconds

  # Memory configuration
  config.conversation_history_limit = 20
  config.conversation_stale_after = 1.day
  config.memory_cleanup_interval = 1.hour

  # Event routing configuration
  config.event_queue_size = 1000
  config.event_processing_timeout = 30.seconds

  # Client pool configuration
  config.max_clients_per_homeserver = 5
  config.client_idle_timeout = 5.minutes

  # Logging
  config.agent_log_level = :info
  config.log_agent_events = Rails.env.development?
end

# Start agent manager on Rails boot (can be disabled in environments)
if Rails.env.production? || ENV['START_AGENTS'].present?
  Rails.application.config.after_initialize do
    ActiveMatrix::AgentManager.instance.start_all
  end
end
