# frozen_string_literal: true

require 'test_helper'

class ApiCSVerificationTest < ActiveSupport::TestCase
  def setup
    @http = mock
    @http.stubs(:active?).returns(true)

    @api = ActiveMatrix::Api.new 'https://example.com', protocols: :CS, autoretry: false, threadsafe: false
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)

    begin
      @fixture = Psych.load_file('test/fixtures/cs_api_methods.yaml', aliases: true)
    rescue ArgumentError
      @fixture = Psych.load_file('test/fixtures/cs_api_methods.yaml')
    end

    # ActiveSupport provides deep_symbolize_keys
  end

  def mock_response(code, body)
    response = Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new(nil, code.to_i, 'GET')
    response.stubs(:stream_check).returns(true)
    response.stubs(:read_body_0).returns(body)
    response.stubs(:body).returns(body)
    response
  end

  def test_fixtures
    @fixture.each do |function, data|
      unless data.key? 'method'
        puts "Skipping test of #{function} due to missing method"
        next
      end
      unless @api.respond_to? data['method']
        puts "Skipping test of #{function} due to unimplemented method #{data['method']}"
        next
      end

      # puts function
      if data.key? 'requests'
        data['requests'].each do |request|
          response = request.fetch('response', {})
          @api.expects(:request).with do |method, _api, path, options|
            options ||= {}
            assert_equal request['method'], method if request.key?('method')
            assert_equal request['path'], path if request.key?('path')
            if request.key?('query')
              if request['query'].nil?
                assert_nil options[:query]
              else
                assert_equal request['query'], options[:query]
              end
            end

            if request.key?('body')
              if request['body'].nil?
                assert_nil options[:body]
              else
                assert_equal request['body'], options[:body]
              end
            end

            if request.key? 'headers'
              request['headers'].each do |header, expected|
                assert_equal expected, options[:headers][header]
              end
            end

            true
          end.returns(response)

          args = request['args']
          # Handle both Hash and Array args
          symbolized_args = if args.is_a?(Hash)
                              args.deep_symbolize_keys
                            elsif args.is_a?(Array)
                              args.map { |arg| arg.is_a?(Hash) ? arg.deep_symbolize_keys : arg }
                            else
                              args
                            end
          assert(call_api(data['method'], symbolized_args))
          @api.unstub(:request)
        end
      end

      next unless data.key? 'results'

      data['results'].each do |code, body|
        @http.expects(:request).returns(mock_response(code, body))

        args = if data.key?('requests') && data['requests'].first && data['requests'].first['args']
                 request_args = data['requests'].first['args']
                 if request_args.is_a?(Hash)
                   request_args.deep_symbolize_keys
                 elsif request_args.is_a?(Array)
                   request_args.map { |arg| arg.is_a?(Hash) ? arg.deep_symbolize_keys : arg }
                 else
                   request_args
                 end
               else
                 []
               end

        if code.to_s[0] == '2'
          assert(!call_api(data['method'], args).nil?)
        else
          assert_raises(ActiveMatrix::MatrixRequestError.class_by_code(code)) { call_api(data['method'], args) }
        end

        @http.unstub(:request)
      end
    end
  end

  def call_api(method, args)
    required_arguments_size = @api.method(method).parameters.select { |type, _| type == :req }.size

    if args.size == required_arguments_size || !args.last.is_a?(Hash)
      @api.send(method, *args)
    else
      @api.send(method, *args[0..-2], **args.last)
    end
  end
end
