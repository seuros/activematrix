# frozen_string_literal: true

module ActiveMatrix
  module Bot
    # Fits a parsed command onto a command block's parameters: positional
    # parameters take the arguments, keyword parameters take the flags.
    #
    #   command :deploy do |target, region = 'eu', force: false| ... end
    #   !deploy api                 -> ('api', force: false)
    #   !deploy api us --force      -> ('api', 'us', force: true)
    #   !deploy                     -> usage: "TARGET [REGION] [--force]"
    class Arguments
      attr_reader :positional, :keywords

      def initialize(block, parsed)
        # As written: a plain block reports every positional parameter as optional.
        @parameters = block.parameters(lambda: true)
        @positional = parsed.args
        @flags = parsed.flags.transform_keys(&:to_sym)
        @keywords = rest?(:keyrest) ? @flags : @flags.slice(*keyword_names)
      end

      def valid?
        count = positional.size
        return false if count < required.size
        return false if !rest?(:rest) && count > required.size + optional.size
        return false if (required_keywords - keywords.keys).any?

        rest?(:keyrest) || (@flags.keys - keyword_names).empty?
      end

      def usage
        parts = required.map { it.to_s.upcase } + optional.map { "[#{it.to_s.upcase}]" }
        parts << '[ARGS...]' if rest?(:rest)
        parts += @parameters.filter_map { |type, name| "[--#{name.to_s.tr('_', '-')}]" if type == :key }
        parts += required_keywords.map { "--#{it.to_s.tr('_', '-')}=VALUE" }
        parts.join(' ')
      end

      private

      def required = names(:req)
      def optional = names(:opt)
      def required_keywords = names(:keyreq)
      def keyword_names = names(:key) + names(:keyreq)
      def names(type) = @parameters.filter_map { |kind, name| name if kind == type }
      def rest?(type) = @parameters.any? { |kind, _| kind == type }
    end
  end
end
