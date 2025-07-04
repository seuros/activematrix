# frozen_string_literal: true

require 'optparse'

module ActiveMatrix
  module Bot
    PARAMS_CONFIG = {} # rubocop:disable Style/MutableConstant Intended

    class << self
      def parse_arguments!
        parser = OptionParser.new do |op|
          op.on('-s homeserver', 'Specify homeserver') { |val| PARAMS_CONFIG[:homeserver] = val }

          op.on('-T token', 'Token') { |val| PARAMS_CONFIG[:access_token] = val }
          op.on('-U username', 'Username') { |val| PARAMS_CONFIG[:username] = val }
          op.on('-P password', 'Password') { |val| PARAMS_CONFIG[:password] = val }

          op.on('-q', 'Disable logging') { PARAMS_CONFIG[:logging] = false }
          op.on('-v', 'Enable verbose output') { PARAMS_CONFIG[:logging] = !(PARAMS_CONFIG[:log_level] = :debug).nil? }
        end

        begin
          parser.parse!(ARGV.dup)
        rescue StandardError => e
          PARAMS_CONFIG[:optparse_error] = e
        end

        ActiveMatrix.debug! if ENV['MATRIX_DEBUG'] == '1'
      end
    end

    class Instance < Base
      set :logging, true
      set :log_level, :info

      set :app_file, caller_files.first || $PROGRAM_NAME
      set(:run) { File.expand_path($PROGRAM_NAME) == File.expand_path(app_file) }

      if run? && ARGV.any?
        Bot.parse_arguments!
        error = PARAMS_CONFIG.delete(:optparse_error)
        raise error if error

        PARAMS_CONFIG.each { |k, v| set k, v }
      end
    end
  end
end
