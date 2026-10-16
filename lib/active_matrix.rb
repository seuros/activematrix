# frozen_string_literal: true

require_relative 'active_matrix/version'

require 'zeitwerk'
require 'active_record'
require 'active_job'
require 'state_machines-activerecord'

# Rails-native Matrix bot framework. Matrix I/O lives in the activematrixd
# daemon; Rails talks to it through Postgres.
module ActiveMatrix
  Loader = Zeitwerk::Loader.for_gem
  Loader.ignore("#{__dir__}/generators")
  Loader.ignore("#{__dir__}/activematrix.rb")
  # Loaded by exe/activematrix without Rails, so required, not autoloaded.
  Loader.ignore("#{__dir__}/active_matrix/daemon.rb")
  Loader.inflector.inflect('mxid' => 'MXID')
  Loader.setup
end

require_relative 'active_matrix/daemon'
require 'active_matrix/engine'
