# frozen_string_literal: true

require 'async'
require 'async/http'
require 'json'

module ActiveMatrix
  class Daemon
    # Lightweight HTTP health probe server using Async::HTTP
    #
    # Endpoints:
    # - GET /health - Returns 200 if healthy, 503 if shutting down
    # - GET /status - Returns detailed JSON status
    # - GET /metrics - Prometheus-compatible metrics
    #
    class ProbeServer
      attr_reader :host, :port, :daemon

      def initialize(host:, port:, daemon:)
        @host = host
        @port = port
        @daemon = daemon
        @thread = nil
      end

      def start
        @thread = Thread.new do
          Sync do
            endpoint = Async::HTTP::Endpoint.parse("http://#{host}:#{port}")

            @server = Async::HTTP::Server.for(endpoint) do |request|
              handle_request(request)
            end

            logger.info "Probe server listening on #{host}:#{port}"
            @server.run
          end
        rescue StandardError => e
          logger.error "Probe server error: #{e.message}"
        end
      end

      def stop
        @thread&.kill
        @thread&.join(1)
      end

      private

      def handle_request(request)
        path = request.path

        case path
        when '/health'
          health_response
        when '/status'
          status_response
        when '/metrics'
          metrics_response
        else
          not_found_response
        end
      end

      def health_response
        status = daemon.status
        code = status[:status] == 'ok' ? 200 : 503

        ::Protocol::HTTP::Response[code, { 'content-type' => 'text/plain' }, [status[:status]]]
      end

      def status_response
        body = JSON.pretty_generate(daemon.status)

        ::Protocol::HTTP::Response[200, { 'content-type' => 'application/json' }, [body]]
      end

      def metrics_response
        status = daemon.status

        lines = [
          '# HELP activematrix_up Is the daemon running',
          '# TYPE activematrix_up gauge',
          "activematrix_up #{status[:status] == 'ok' ? 1 : 0}",
          '',
          '# HELP activematrix_uptime_seconds Daemon uptime in seconds',
          '# TYPE activematrix_uptime_seconds counter',
          "activematrix_uptime_seconds #{status[:uptime]}",
          '',
          '# HELP activematrix_workers Number of worker processes',
          '# TYPE activematrix_workers gauge',
          "activematrix_workers #{status[:workers]}",
          '',
          '# HELP activematrix_agents_total Total number of agents',
          '# TYPE activematrix_agents_total gauge',
          "activematrix_agents_total #{status.dig(:agents, :total) || 0}",
          '',
          '# HELP activematrix_agents Agent count by state',
          '# TYPE activematrix_agents gauge',
          "activematrix_agents{state=\"online\"} #{status.dig(:agents, :online) || 0}",
          "activematrix_agents{state=\"connecting\"} #{status.dig(:agents, :connecting) || 0}",
          "activematrix_agents{state=\"error\"} #{status.dig(:agents, :error) || 0}",
          "activematrix_agents{state=\"offline\"} #{status.dig(:agents, :offline) || 0}"
        ]

        ::Protocol::HTTP::Response[200, { 'content-type' => 'text/plain; version=0.0.4' }, [lines.join("\n")]]
      end

      def not_found_response
        ::Protocol::HTTP::Response[404, { 'content-type' => 'text/plain' }, ['Not Found']]
      end

      def logger
        ActiveMatrix.logger
      end
    end
  end
end
