# frozen_string_literal: true

module ActiveMatrix
  module Bot
    # An agent's settings, typed by the bot's `setting` declarations:
    # `settings.greeting`, `settings[:greeting]`. Undeclared keys read as
    # stored; declared ones are cast, with their default when unset.
    class Settings
      # JSON already holds these as they are.
      STRUCTURED = %i[array hash json].freeze

      def initialize(stored, definitions)
        @stored = (stored || {}).stringify_keys
        @definitions = definitions
      end

      def [](name)
        name = name.to_s
        definition = @definitions[name]
        return @stored[name] unless definition
        return definition.default unless @stored.key?(name)
        return @stored[name] if STRUCTURED.include?(definition.type)

        ActiveModel::Type.lookup(definition.type).cast(@stored[name])
      end

      def respond_to_missing?(name, include_private = false) = @definitions.key?(name.to_s) || super

      def method_missing(name, *args)
        return super unless args.empty? && @definitions.key?(name.to_s)

        self[name]
      end
    end
  end
end
