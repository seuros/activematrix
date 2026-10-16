# frozen_string_literal: true

module ActiveMatrix
  module Bot
    # Parses a message into a command: `!deploy api --force --region=eu`.
    #
    # - The prefix must start the message, and the command name follows it
    #   directly (`! deploy` is not a command).
    # - Arguments split on whitespace. Quotes group words, but only when they
    #   open an argument, so "don't" stays one word.
    # - `--name` is a flag set to true, `--name=value` one with a value, and a
    #   bare `--` ends flags: everything after it is positional.
    # - `rest` is the text after the command name exactly as typed, for
    #   commands that take free text.
    class CommandParser
      Command = Data.define(:prefix, :name, :args, :flags, :rest)

      # The command in `text`, or nil when it is not one.
      def self.parse(text, prefixes: ['!'])
        text = text.to_s.strip
        prefix = prefixes.find { text.start_with?(it) }
        return unless prefix

        name, rest = text.delete_prefix(prefix).split(/\s+/, 2)
        return if name.blank? || !name.match?(/\A[\p{L}\p{N}_-]+\z/)

        args, flags = split_flags(tokenize(rest.to_s))
        Command.new(prefix:, name: name.downcase, args:, flags:, rest: rest.to_s.strip)
      end

      def self.tokenize(text)
        tokens = []
        scanner = StringScanner.new(text)
        until scanner.eos?
          scanner.skip(/\s+/)
          break if scanner.eos?

          tokens << (scanner.scan(/"([^"]*)"|'([^']*)'/) ? (scanner[1] || scanner[2]) : scanner.scan(/\S+/))
        end
        tokens
      end

      def self.split_flags(tokens)
        args = []
        flags = {}
        literal = false
        tokens.each do |token|
          if literal || !token.start_with?('--')
            args << token
          elsif token == '--'
            literal = true
          else
            name, value = token.delete_prefix('--').split('=', 2)
            flags[name.tr('-', '_')] = value.nil? || value
          end
        end
        [args, flags]
      end

      private_class_method :tokenize, :split_flags
    end
  end
end
