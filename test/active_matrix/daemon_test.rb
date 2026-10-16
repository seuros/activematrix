# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class DaemonTest < ActiveSupport::TestCase
  test 'ACTIVEMATRIX_INSTALL_DIR wins over the bundled binary' do
    Dir.mktmpdir do |dir|
      binary = File.join(dir, 'activematrixd')
      File.write(binary, "#!/bin/sh\n")
      File.chmod(0o755, binary)
      ENV['ACTIVEMATRIX_INSTALL_DIR'] = dir

      assert_equal binary, ActiveMatrix::Daemon.executable
    end
  end

  test 'ACTIVEMATRIX_INSTALL_DIR without an executable binary is an error' do
    Dir.mktmpdir do |dir|
      ENV['ACTIVEMATRIX_INSTALL_DIR'] = dir

      error = assert_raises(ActiveMatrix::Daemon::NotFound) { ActiveMatrix::Daemon.executable }
      assert_includes error.message, dir
    end
  end

  test 'the platformless gem explains how to get a binary' do
    ENV.delete('ACTIVEMATRIX_INSTALL_DIR')
    ActiveMatrix::Daemon.stubs(:bundled_path).returns('/nonexistent/activematrixd')

    error = assert_raises(ActiveMatrix::Daemon::NotFound) { ActiveMatrix::Daemon.executable }
    assert_includes error.message, 'ACTIVEMATRIX_INSTALL_DIR'
  end
end
