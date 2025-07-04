# frozen_string_literal: true

require 'uri'

module ActiveMatrix
  module Uri
    # A mxc:// Matrix content URL
    class MXC < ::URI::Generic
      def full_path
        select(:host, :port, :path, :query, :fragment)
          .compact
          .join
      end
    end

    # A matrix: URI according to MSC2312
    class MATRIX < ::URI::Generic
      attr_reader :authority, :action, :mxid, :mxid2, :via

      def initialize(*)
        super

        @action = nil
        @authority = nil
        @mxid = nil
        @mxid2 = nil
        @via = nil

        raise InvalidComponentError, 'missing opaque part for matrix URL' if !@opaque && !@path

        if @path
          @authority = @host
          @authority += ":#{@port}" if @port
        else
          @path, @query = @opaque.split('?')
          @query, @fragment = @query.split('#') if @query&.include? '#'
          @path, @fragment = @path.split('#') if @path&.include? '#'
          @path = "/#{path}"
          @opaque = nil
        end

        components = @path.delete_prefix('/').split('/', -1)
        raise InvalidComponentError, 'component count must be 2 or 4' if components.size != 2 && components.size != 4

        sigil = case components.shift
                when 'u', 'user'
                  '@'
                when 'r', 'room'
                  '#'
                when 'roomid'
                  '!'
                else
                  raise InvalidComponentError, 'invalid component in path'
                end

        component = components.shift
        raise InvalidComponentError, "component can't be empty" if component.blank?

        @mxid = ActiveMatrix::MXID.new("#{sigil}#{component}")

        if components.size == 2
          sigil2 = case components.shift
                   when 'e', 'event'
                     '$'
                   else
                     raise InvalidComponentError, 'invalid component in path'
                   end
          component = components.shift
          raise InvalidComponentError, "component can't be empty" if component.blank?

          @mxid2 = ActiveMatrix::MXID.new("#{sigil2}#{component}")
        end

        return unless @query

        @action = @query.match(/action=([^&]+)/)&.captures&.first&.to_sym
        @via = @query.scan(/via=([^&]+)/)&.flatten&.compact
      end

      def mxid2?
        !@mxid2.nil?
      end
    end

    # Register URI schemes using modern Ruby
    ::URI.register_scheme 'MXC', MXC
    ::URI.register_scheme 'MATRIX', MATRIX unless ::URI.scheme_list.key?('MATRIX')

    # Make them available in URI namespace for backward compatibility
    ::URI.const_set(:MXC, MXC) unless ::URI.const_defined?(:MXC)
    ::URI.const_set(:MATRIX, MATRIX) unless ::URI.const_defined?(:MATRIX)
  end
end
