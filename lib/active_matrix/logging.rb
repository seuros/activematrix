# frozen_string_literal: true

module ActiveMatrix
  module Logging
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def logger
        @logger ||= ActiveMatrix.logger
      end

      def logger=(logger)
        @logger = logger
      end
    end

    def logger
      @logger ||= self.class.logger
    end

    def logger=(logger)
      @logger = logger
    end
  end

  class << self
    def logger
      @logger ||= if defined?(::Rails) && ::Rails.respond_to?(:logger)
                    ::Rails.logger
                  else
                    # Fallback for testing
                    require 'logger'
                    ::Logger.new($stdout)
                  end
    end

    def logger=(logger)
      @logger = logger
      @global_logger = !logger.nil?
    end

    def debug!
      logger.level = if defined?(::Rails)
                       :debug
                     else
                       ::Logger::DEBUG
                     end
    end

    def global_logger?
      @global_logger ||= false
    end
  end
end
