# frozen_string_literal: true

require 'open3'
require 'shuttlebay/attached'
require 'socket'

module SystemTests
  # Where the binaries under test are: ACTIVEMATRIX_INSTALL_DIR (rake
  # test:system points it at cargo's debug build), else cargo's debug build.
  module Binaries
    module_function

    def dir
      ENV.fetch('ACTIVEMATRIX_INSTALL_DIR') do
        File.join(ENV.fetch('CARGO_TARGET_DIR', File.expand_path('../../../target', __dir__)), 'debug')
      end
    end

    def daemon = executable('activematrixd')
    def fakehs = ENV.fetch('ACTIVEMATRIX_FAKEHS') { executable('activematrix-fakehs') }

    def executable(name)
      path = File.join(dir, name)
      return path if File.executable?(path)

      raise "#{path} is missing: run `bundle exec rake test:system`, which builds it"
    end
  end

  # The dummy app over real HTTP, the way the daemon reaches Rails in
  # production: shuttlebay with an attached mothership, inside the test's cell.
  class RailsServer
    def self.start(app) = new(app).tap(&:start)

    attr_reader :port

    def initialize(app)
      @app = app
    end

    def start
      # Mothership binds the port, so pick a free one first.
      @port = TCPServer.open('127.0.0.1', 0) { it.addr[1] }
      @server = Shuttlebay::Attached.new(@app, Host: '127.0.0.1', Port: @port, Threads: 4, Silent: true,
                                               trap_signals: false)
      @thread = Thread.new { @server.run }
      @thread.report_on_exception = false
      wait_until_serving
    end

    def url(path) = "http://127.0.0.1:#{port}#{path}"

    def stop
      @server&.stop
      @thread&.join(10)
    end

    private

    def wait_until_serving(timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until serving?
        @thread.value unless @thread.alive? # re-raises why it stopped
        raise "the app was not served within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end

    # Mothership answers 502 until the app's worker has docked.
    def serving?
      ![502, 503, 504].include?(Net::HTTP.get_response(URI(url('/'))).code.to_i)
    rescue SystemCallError, IOError, Net::ReadTimeout
      false
    end
  end

  # One activematrixd, configured through the environment as in production,
  # logging to a file that a failing test prints.
  class DaemonProcess
    attr_reader :log

    def initialize(env, dir)
      @env = env
      @dir = dir
      @log = File.join(dir, "activematrixd-#{SecureRandom.hex(3)}.log")
    end

    # A one-shot command (login, check), with `stdin` as its input.
    def run!(*args, stdin: '')
      output, status = Open3.capture2e(@env, Binaries.daemon, *args, stdin_data: stdin, chdir: @dir)
      raise "activematrixd #{args.join(' ')} failed (#{status}):\n#{output}" unless status.success?

      output
    end

    def start
      @pid = Process.spawn(@env, Binaries.daemon, 'start', chdir: @dir, in: File::NULL, %i[out err] => [@log, 'a'])
      self
    end

    def running? = !@pid.nil?

    # Signals the daemon and waits for it to exit. Returns its status and how
    # long it took; a daemon still running after `timeout` is killed.
    def stop(signal: 'TERM', timeout: 15)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill(signal, @pid)
      status = wait(timeout)
      unless status
        Process.kill('KILL', @pid)
        Process.wait(@pid)
        raise "activematrixd did not exit within #{timeout}s of #{signal}"
      end
      [status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    ensure
      @pid = nil
    end

    def kill
      return unless @pid

      Process.kill('KILL', @pid)
      Process.wait(@pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @pid = nil
    end

    private

    def wait(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        _, status = Process.wait2(@pid, Process::WNOHANG)
        return status if status
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
  end
end
