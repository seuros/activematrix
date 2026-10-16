# frozen_string_literal: true

module ActiveMatrix
  # Locates and launches the precompiled activematrixd daemon.
  #
  # Platform gems ship the binary in libexec/. ACTIVEMATRIX_INSTALL_DIR points
  # at any other build: a platform without a gem, or a local cargo build.
  #
  # Standalone on purpose: exe/activematrix requires this file without loading
  # Rails, because the daemon talks to Postgres and Matrix, not to the app.
  module Daemon
    BINARY = 'activematrixd'

    class NotFound < StandardError; end

    module_function

    def executable
      dir = ENV.fetch('ACTIVEMATRIX_INSTALL_DIR', nil)
      return installed_in(dir) if dir
      return bundled_path if File.executable?(bundled_path)

      raise NotFound, <<~MSG
        No activematrixd binary for #{platform}: this is the platformless gem.
        Build the daemon and point at it:

          cargo build --release -p activematrixd
          export ACTIVEMATRIX_INSTALL_DIR=/path/to/activematrix/target/release
      MSG
    end

    def installed_in(dir)
      path = File.expand_path(BINARY, dir)
      return path if File.executable?(path)

      raise NotFound, "ACTIVEMATRIX_INSTALL_DIR is set to #{dir}, but #{path} is not executable"
    end

    # libexec/ beside lib/: the gem root when installed, the repo root in a
    # checkout. Not exe/, which holds the Ruby launcher RubyGems installs.
    def bundled_path = File.expand_path("../../libexec/#{BINARY}", __dir__)

    def platform = "#{Gem::Platform.local.cpu}-#{Gem::Platform.local.os}"

    # exec, not spawn: a supervisor (systemd, Docker, Kubernetes) should see
    # the daemon's own exit status and signals, not a Ruby parent's.
    def exec!(*) = Kernel.exec(executable, *)
  end
end
