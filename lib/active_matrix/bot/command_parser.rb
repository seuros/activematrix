# frozen_string_literal: true

module ActiveMatrix
  module Bot
    # Parses command arguments with support for flags and quoted strings
    #
    # @example Basic parsing
    #   parser = CommandParser.new('search "hello world" --verbose')
    #   parser.args        # => ["search", "hello world"]
    #   parser.flags       # => { "verbose" => true }
    #
    # @example With key-value flags
    #   parser = CommandParser.new('greet --name=Alice --formal')
    #   parser.positional_args  # => []
    #   parser.flags            # => { "name" => "Alice", "formal" => true }
    #
    class CommandParser
      attr_reader :raw_input, :command_name, :args, :raw_args

      # Command prefixes recognized by the parser
      COMMAND_PREFIXES = ['/', '!'].freeze

      # @param input [String] Raw command input
      # @param prefixes [Array<String>] Command prefixes to recognize
      def initialize(input, prefixes: COMMAND_PREFIXES)
        @raw_input = input.to_s.strip
        @prefixes = prefixes
        @command_name = nil
        @args = []
        @raw_args = ''
        @parsed_flags = nil
        parse!
      end

      # Check if input is a valid command (has prefix and command name)
      #
      # @return [Boolean]
      def command?
        !@command_name.nil? && @prefixes.any? { |prefix| @raw_input.start_with?(prefix) }
      end

      # Get the prefix used in the command
      #
      # @return [String, nil]
      def prefix
        @prefixes.find { |p| @raw_input.start_with?(p) }
      end

      # Parse flags and positional arguments
      #
      # @return [Hash] Hash with :flags and :args keys
      def parse_flags
        @parsed_flags ||= begin
          flags = {}
          positional = []

          @args.each do |arg|
            case arg
            when /\A--([^=]+)=(.+)\z/
              # --key=value format
              flags[Regexp.last_match(1)] = Regexp.last_match(2)
            when /\A--(.+)\z/
              # --flag format (boolean)
              flags[Regexp.last_match(1)] = true
            when /\A-([a-zA-Z]+)\z/
              # Short flags like -v, -abc (multiple)
              Regexp.last_match(1).chars.each { |c| flags[c] = true }
            else
              positional << arg
            end
          end

          { flags: flags, args: positional }
        end
      end

      # Get only positional arguments (no flags)
      #
      # @return [Array<String>]
      def positional_args
        parse_flags[:args]
      end

      # Get only flag arguments
      #
      # @return [Hash<String, Object>]
      def flags
        parse_flags[:flags]
      end

      # Check if a specific flag is set
      #
      # @param name [String] Flag name (without dashes)
      # @return [Boolean]
      def flag?(name)
        flags.key?(name.to_s)
      end

      # Get a flag value
      #
      # @param name [String] Flag name
      # @param default [Object] Default value if flag not set
      # @return [Object]
      def flag(name, default = nil)
        flags.fetch(name.to_s, default)
      end

      # Formatted command string
      #
      # @return [String]
      def formatted_command
        return '' unless command?

        [@command_name, *@args].join(' ')
      end

      private

      def parse!
        # Check if input starts with a valid prefix
        found_prefix = @prefixes.find { |p| @raw_input.start_with?(p) }
        return unless found_prefix

        # Remove prefix
        content = @raw_input[found_prefix.length..].strip
        return if content.empty?

        # Parse respecting quoted strings
        parts = parse_with_quotes(content)
        return if parts.empty?

        @command_name = parts.first.downcase
        @args = parts[1..] || []
        @raw_args = @args.join(' ')
      end

      def parse_with_quotes(input)
        parts = []
        current = +''
        in_quotes = false
        quote_char = nil

        input.each_char do |char|
          case char
          when '"', "'"
            if in_quotes && char == quote_char
              # End of quoted section
              in_quotes = false
              quote_char = nil
            elsif !in_quotes
              # Start of quoted section
              in_quotes = true
              quote_char = char
            else
              # Different quote inside quotes, treat as literal
              current << char
            end
          when ' ', "\t"
            if in_quotes
              current << char
            elsif current.length.positive?
              parts << current
              current = +''
            end
          else
            current << char
          end
        end

        parts << current if current.length.positive?
        parts
      end
    end
  end
end
