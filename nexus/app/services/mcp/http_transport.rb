module Mcp
  # Keep the official client's lifecycle, envelope and header rules; the wire
  # adapter deliberately has no OAuth, reconnect, redirect or POST retry path.
  class HttpTransport < MCP::Client::HTTP
    MAX_TIMEOUT_SECONDS = 60
    CLOSE_TIMEOUT_SECONDS = 2
    CANCEL_CHECK_SECONDS = 0.2

    # A response cannot select another network destination. Besides refusing
    # Alt-Svc, this avoids HTTPX 1.8's malformed Alt-Svc parser stalling its loop.
    module FixedOrigin
      module ResponseMethods
        def initialize(*)
          super
          @headers.delete("alt-svc")
        end

        def merge_headers(*)
          super
          @headers.delete("alt-svc")
        end
      end

      module ConnectionMethods
        private

          def build_altsvc_connection(*) = nil
      end
    end

    attr_reader :tool_request_sent

    def initialize(endpoint_url:, bearer_token: nil, timeout_seconds:, cancelled: -> { false })
      uri = Nexus::McpEndpoint.parse(endpoint_url)
      timeout = [Float(timeout_seconds), MAX_TIMEOUT_SECONDS].min
      raise Error.new(:mcp_timeout) unless timeout.finite? && timeout.positive?

      super(url: uri.to_s, headers: bearer_token ? { "Authorization" => "Bearer #{bearer_token}" } : {})
      @deadline = monotonic_time + timeout
      @cancelled = cancelled
      @next_cancel_check = 0
      @tool_request_sent = false
      @session = HTTPX.plugin(:ssrf_filter).plugin(:stream).plugin(FixedOrigin).plugin(Nexus::HttpDeadline)
        .with(persistent: false, debug: nil, debug_redact: true, headers: { "Accept" => ACCEPT_HEADER })
    rescue Nexus::McpEndpoint::Invalid
      raise Error.new(:mcp_invalid_endpoint), cause: nil
    end

    def send_request(request:)
      method = request.fetch(:method)
      @tool_request_sent = false if method == MCP::Methods::TOOLS_CALL
      check_cancelled(force: true)
      if modern? && request.key?(:id)
        request = MCP::Client::ModernEnvelope.stamp(request, protocol_version: @protocol_version,
          client_info: @modern_client_info, capabilities: @modern_capabilities)
      end
      request_headers = headers.merge(session_headers).merge(request_metadata_headers(method, request[:params]))
      response, body = exchange("POST", request, request_headers, method: method)
      capture_session_info(method, response, body)
      capture_mcp_param_declarations(method, request[:params], body)
      # Only absence of discovery permits the gem's automatic legacy fallback.
      # Authentication, malformed responses and ordinary server errors never do.
      if method == MCP::Methods::SERVER_DISCOVER && body&.key?("error") && body.dig("error", "code") != -32601
        raise Error.new(:mcp_protocol_error)
      end
      body
    end

    def send_notification(notification:)
      send_request(request: notification)
      nil
    end

    def close
      # Session deletion is disposable transport cleanup, with its own short
      # budget even when the operation timed out or was cancelled.
      if session_id
        @deadline = monotonic_time + CLOSE_TIMEOUT_SECONDS
        @cancelled = -> { false }
        exchange("DELETE", nil, headers.merge(session_headers), method: nil)
      end
    rescue Error
      nil
    ensure
      close_session
      clear_session
    end

    private

      def close_session
        @session&.close
      rescue HTTPX::Error, SystemCallError, IOError
        nil
      end

      def exchange(verb, request, request_headers, method:)
        remaining = remaining_time
        stream = @session.request(verb, url, headers: request_headers,
          **(request ? { json: request } : {}), stream: true,
          timeout: { connect_timeout: [5, remaining].min, request_timeout: remaining,
                     read_timeout: remaining, write_timeout: remaining, operation_timeout: remaining })
        stream.request.on(:headers) do
          check_cancelled(force: true)
          @tool_request_sent = true if method == MCP::Methods::TOOLS_CALL
        end
        yield if block_given?
        read_response(stream, request)
      rescue HTTPX::HTTPError => error
        raise failure(http_error_code(error.response.status)), cause: nil
      rescue HTTPX::ServerSideRequestForgeryError
        raise failure(:mcp_endpoint_refused), cause: nil
      rescue HTTPX::TimeoutError
        raise failure(:mcp_timeout), cause: nil
      rescue HTTPX::Error, SystemCallError, IOError, URI::InvalidURIError
        raise failure(:mcp_transport_error), cause: nil
      end

      def read_response(stream, request)
        body = +""
        answer = nil
        bytes = 0
        parser = EventStreamParser::Parser.new
        stream.each do |chunk|
          check_cancelled
          remaining_time
          response = stream.request.response
          raise failure(http_error_code(response.status)) unless response.status.between?(200, 299)

          mime_type = response.headers["content-type"].to_s.split(";", 2).first.to_s.strip.downcase
          unless %w[application/json text/event-stream].include?(mime_type)
            raise failure(:mcp_protocol_error)
          end

          bytes += chunk.bytesize
          raise failure(:mcp_response_too_large) unless Nexus::SizeBounds.bytes_within?(:inline_binary_bound, bytes)

          if mime_type == "text/event-stream"
            parser.feed(chunk) do |_type, data, _id, _retry|
              next if data.to_s.empty?

              message = parse_message(data)
              if message.key?("result") || message.key?("error")
                answer = validate_response(message, request)
              elsif message.key?("id")
                raise failure(:mcp_unsupported_server_request)
              end
            end
            break if answer
          else
            body << chunk
          end
        end
        response = stream.request.response
        raise failure(http_error_code(response.status)) unless response.status.between?(200, 299)
        return [response, nil] if request.nil? || !request.key?(:id)
        raise failure(:mcp_protocol_error) if response.status == 202

        answer ||= validate_response(parse_message(body), request)
        [response, answer]
      end

      def parse_message(data)
        message = Hash.try_convert(JSON.parse(data))
        raise failure(:mcp_protocol_error) unless message && message["jsonrpc"] == "2.0"

        message
      rescue JSON::ParserError, EncodingError
        raise failure(:mcp_protocol_error), cause: nil
      end

      def validate_response(message, request)
        unless request && message["id"] == request[:id] &&
            (message.key?("result") ^ message.key?("error")) &&
            Hash.try_convert(message[message.key?("result") ? "result" : "error"])
          raise failure(:mcp_protocol_error)
        end
        validate_tool_page(message.fetch("result")) if request[:method] == MCP::Methods::TOOLS_LIST && message.key?("result")
        message
      end

      def validate_tool_page(result)
        tools = Array.try_convert(result["tools"])
        raise failure(:mcp_invalid_catalog) unless tools

        tools.each do |value|
          tool = Hash.try_convert(value)
          raise failure(:mcp_invalid_catalog) unless tool

          # The SDK normally omits invalid header declarations and warns with
          # the remote name. Discovery here publishes a complete catalog or none.
          if modern? && !MCP::Client::McpParamHeaders.scan(tool["inputSchema"]).fetch(:valid)
            raise failure(:mcp_invalid_catalog)
          end
        end
      end

      def http_error_code(status)
        case status
        when 300..399 then :mcp_redirect_refused
        when 401, 403 then :mcp_authentication_failed
        when 429 then :mcp_rate_limited
        else :mcp_http_error
        end
      end

      def check_cancelled(force: false)
        now = monotonic_time
        if force || now >= @next_cancel_check
          @next_cancel_check = now + CANCEL_CHECK_SECONDS
          raise failure(:mcp_cancelled) if @cancelled.call
        end
      end

      def remaining_time
        remaining = @deadline - monotonic_time
        raise failure(:mcp_timeout) unless remaining.positive?

        remaining
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def failure(code) = Error.new(code, request_sent: tool_request_sent)
  end
end
