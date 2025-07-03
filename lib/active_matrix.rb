# frozen_string_literal: true

require_relative 'active_matrix/version'
require_relative 'active_matrix/logging'
require_relative 'active_matrix/util/extensions'
require_relative 'active_matrix/util/uri'
require_relative 'active_matrix/util/events'
require_relative 'active_matrix/errors'

require 'json'
require 'zeitwerk'

module ActiveMatrix
  # Set up Zeitwerk loader
  Loader = Zeitwerk::Loader.for_gem
  
  # Configure inflections for special cases
  Loader.inflector.inflect(
    'mxid' => 'MXID',
    'uri' => 'URI',
    'as' => 'AS',
    'cs' => 'CS',
    'is' => 'IS', 
    'ss' => 'SS',
    'msc' => 'MSC'
  )

  # Setup Zeitwerk autoloading
  Loader.setup
  
  # Load Railtie for Rails integration
  require 'active_matrix/railtie' if defined?(Rails::Railtie)
end
