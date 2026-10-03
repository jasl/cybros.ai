require "async"
require "json"
require "uri"
require "stringio"
require "telegram/bot"
require "httpx/adapters/faraday"

module Rho
  module IngressTelegram
    class Client
      class Refused < StandardError
        attr_reader :code, :retry_after, :description

        def initialize(code:, description:, retry_after: nil)
          @code, @description, @retry_after = code, description, retry_after
          super("Telegram refused the request (#{code}): #{description}")
        end
      end

      class Unavailable < StandardError
        attr_reader :reason, :ambiguous

        def initialize(reason:, ambiguous:)
          @reason, @ambiguous = reason, ambiguous
          super("Telegram request unavailable (#{reason}); delivery #{ambiguous ? "may have occurred" : "did not occur"}")
        end
      end

      # Keep the gem's endpoint and multipart encoding, but make transport settings
      # instance-owned. Telegram::Bot.configure otherwise changes every bot at once.
      class Wire < Telegram::Bot::Api
        def initialize(token, url:, timeout:, open_timeout:)
          super(token, url: url)
          @connection = Faraday.new(url: url) do |faraday|
            faraday.request :multipart
            faraday.request :url_encoded
            faraday.adapter :httpx, max_retries: 0,
              pool_options: { max_connections: 1, max_connections_per_origin: 1, pool_timeout: open_timeout }
            faraday.options.timeout = timeout
            faraday.options.open_timeout = open_timeout
          end
        end
      end
      private_constant :Wire

      def initialize(token:, url: "https://api.telegram.org", timeout: 15, poll_timeout: 40, open_timeout: 5)
        @token = token.to_s
        raise ArgumentError, "Telegram token is required" if @token.empty?

        uri = URI.parse(url.to_s)
        unless %w[https http].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
          raise ArgumentError, "Telegram endpoint must be an HTTP(S) origin"
        end
        if uri.path != "" && uri.path != "/"
          raise ArgumentError, "Telegram endpoint must be an HTTP(S) origin"
        end
        values = [timeout, poll_timeout, open_timeout].map { |value| Float(value) }
        unless values.all? { |value| value.finite? && value.positive? }
          raise ArgumentError, "Telegram timeouts must be positive and finite"
        end
        timeout, poll_timeout, open_timeout = values
        # A held HTTP/1.1 poll must not occupy the sending connection.
        @send_api = Wire.new(@token, url: uri.to_s, timeout: timeout, open_timeout: open_timeout)
        @poll_api = Wire.new(@token, url: uri.to_s, timeout: poll_timeout, open_timeout: open_timeout)
        @file_api = Wire.new(@token, url: uri.to_s, timeout: timeout, open_timeout: open_timeout)
        @requests = []
        @closed = false
      end

      # Returns raw JSON result values, including fields not known by the gem's
      # generated types. The caller owns admission, offsets and any explicit retry.
      def call(method, params = {}, poll: false)
        raise Unavailable.new(reason: :closed, ambiguous: false) if @closed

        endpoint = method.to_s
        unless endpoint.bytesize <= 80 && /\A[a-zA-Z][a-zA-Z0-9]*\z/.match?(endpoint)
          raise ArgumentError, "Invalid Telegram method name"
        end
        api = poll ? @poll_api : @send_api
        request = Async::Task.current.async { perform(api, endpoint, params.to_h) }
        @requests << request
        result = request.wait
        if request.stopped?
          raise Unavailable.new(reason: :closed, ambiguous: true)
        end
        result
      ensure
        @requests.delete(request) if request
      end

      def upload(method, params, bytes:, filename:, content_type:, field:)
        part = Faraday::Multipart::FilePart.new(StringIO.new(bytes), content_type, filename)
        call(method, params.merge(field.to_sym => part))
      end

      # getFile supplies a path, never a destination URL. Keep the token on the
      # configured Bot API origin, and bound actual streamed bytes as well as
      # the caller's earlier file_size check.
      def download(file_path, max_bytes:)
        raise Unavailable.new(reason: :closed, ambiguous: false) if @closed

        path = file_path.to_s
        unless path.bytesize <= 1024 && /\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*\z/.match?(path) &&
            path.split("/").none? { |segment| %w[. ..].include?(segment) }
          raise ArgumentError, "Invalid Telegram file path"
        end
        limit = Integer(max_bytes)
        raise ArgumentError, "Download limit must be positive" unless limit.positive?

        request = Async::Task.current.async { perform_download(path, limit) }
        @requests << request
        result = request.wait
        raise Unavailable.new(reason: :closed, ambiguous: false) if request.stopped?

        result
      ensure
        @requests.delete(request) if request
      end

      def close
        @closed = true
        @requests.dup.each(&:stop)
        @poll_api.connection.close
        @send_api.connection.close
        @file_api.connection.close
        nil
      end

      # Ruby's default inspect would include the gem client and its token URL.
      def inspect
        "#<#{self.class.name} closed=#{@closed}>"
      end

      private

      def perform_download(path, limit)
        bytes = +"".b
        response = @file_api.connection.get("/file/bot#{@token}/#{path}") do |request|
          request.options.on_data = lambda do |chunk, _size|
            if bytes.bytesize + chunk.bytesize > limit
              raise Refused.new(code: 413, description: "File exceeds the Telegram download limit")
            end
            bytes << chunk
          end
        end
        unless response.status == 200
          raise Unavailable.new(reason: :http_error, ambiguous: false)
        end

        bytes
      rescue Faraday::TimeoutError
        raise Unavailable.new(reason: :timeout, ambiguous: false), cause: nil
      rescue Faraday::ConnectionFailed, Faraday::SSLError, HTTPX::Error, IOError, SystemCallError
        raise Unavailable.new(reason: :connection, ambiguous: false), cause: nil
      end

      def perform(api, method, params)
        read_result(api.call(method, params))
      rescue Telegram::Bot::Exceptions::ResponseError => error
        status = error.response.status
        if status >= 500 || (300...400).cover?(status)
          raise Unavailable.new(reason: :http_error, ambiguous: true), cause: nil
        end
        refuse(error.data.transform_keys(&:to_s), status)
      rescue Faraday::TimeoutError
        raise Unavailable.new(reason: :timeout, ambiguous: true), cause: nil
      rescue Faraday::ConnectionFailed, Faraday::SSLError, HTTPX::Error, IOError, SystemCallError
        raise Unavailable.new(reason: :connection, ambiguous: true), cause: nil
      rescue JSON::ParserError
        raise Unavailable.new(reason: :invalid_response, ambiguous: true), cause: nil
      end

      def read_result(value)
        body = value.to_h
        if body.fetch("ok") == true
          body.fetch("result")
        else
          refuse(body, 400)
        end
      rescue KeyError, TypeError, NoMethodError
        raise Unavailable.new(reason: :invalid_response, ambiguous: true), cause: nil
      end

      def refuse(body, status)
        code = body.fetch("error_code", status).to_i
        description = body.fetch("description", "Request rejected").to_s.gsub(@token, "[FILTERED]")
        retry_after = body.fetch("parameters", {}).to_h["retry_after"]
        retry_after = Integer(retry_after) unless retry_after.nil?
        raise Refused.new(code: code, description: description, retry_after: retry_after), cause: nil
      rescue ArgumentError, TypeError, NoMethodError
        raise Unavailable.new(reason: :invalid_response, ambiguous: true), cause: nil
      end
    end
  end
end
