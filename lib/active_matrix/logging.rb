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
end
