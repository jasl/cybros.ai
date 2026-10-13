require "json"
require "securerandom"
require "timeout"
require "socket"
require "uri"

require_relative "../internal/envelope"
module SimpleInference
  module Protocols
    # Shared protocol helpers (HTTP requests, error handling, JSON parsing).
    #
    # Protocol implementations are responsible for:
    # - building provider-specific URLs/headers/bodies
    # - mapping provider request/response shapes to the app-facing contract
    #
    # This base class provides consistent HTTP error semantics across protocols.
    class Base
      class << self
        # The construction keywords a protocol declares on its own
        # `initialize` beyond the connection settings — what
        # ApiFormat.protocol_for feeds from a profile's wire_options. A
        # typo'd keyword raises ArgumentError at construction.
        def protocol_option_keys
          instance_method(:initialize).parameters.filter_map do |kind, name|
            name if %i[key keyreq].include?(kind)
          end - [:config]
        end

        # The symbol vocabulary a protocol's REQUEST methods accept — the
        # options this protocol processes (or forwards) by name. Everything
        # else must ride the extra_body escape hatch, so a typo'd option can
        # never silently no-op and a provider-specific wire field is always
        # visibly declared at the call site. Introspectable on purpose: the
        # kernel splits its catalog-driven request_options into declared
        # kwargs vs extra_body using this list.
        def request_option_keys
          [].freeze
        end

        # Construction keywords a registry-built protocol reads from its
        # profile's `local_safety_limits` (keyword => limit key): the registry
        # row declares the VALUE, ApiFormat.protocol_for feeds it through this
        # map, and the protocol keeps only the enforcement.
        def local_safety_limit_option_keys
          {}.freeze
        end
      end

      attr_reader :config, :adapter

      # Two construction forms:
      #   new(base_url:, api_key:, ..., <protocol keywords>)  — standalone; parses a Config
      #   new(config: <Config>, <protocol keywords>)          — pass-through; no re-parse
      # (the planner and composing protocols use the second — one Config per
      # Client, built exactly once).
      def initialize(config: nil, **connection)
        if config && !connection.empty?
          raise SimpleInference::ConfigurationError,
                "config: cannot be combined with other connection options (got #{connection.keys.join(", ")})"
        end

        @config = config || Config.new(**connection)
        @adapter = @config.adapter
      end

      # The compiled value already carries serialized request bytes; execution
      # only adds the current credential/connection headers, performs provider
      # IO, and hands the response back to its assembler.
      def compiled_response(compiled, config:, raise_on_http_error: nil)
        handle_response(
          compiled_request_env(compiled, config),
          expect_json: compiled.expect_json,
          raise_on_http_error: raise_on_http_error.nil? ? config.raise_on_error : raise_on_http_error,
          adapter: config.adapter,
        )
      end

      def compiled_stream_response(compiled, config:, raise_on_http_error: nil, &on_event)
        handle_stream_response(
          compiled_request_env(compiled, config),
          raise_on_http_error: raise_on_http_error.nil? ? config.raise_on_error : raise_on_http_error,
          adapter: config.adapter,
          &on_event
        )
      end

      private

      # The common input_file boundary accepts verified bytes only. A file
      # reference beside those bytes is still a conflicting transport request,
      # never permission to upload or fetch it. Storage callers construct the
      # MediaInput once; no protocol sniffs or materializes its source again.
      # Client and direct protocol callers author content parts themselves;
      # RequestValidator checks their declared modality, not the carrier.
      # This is their one carrier gate before the four lowerings read bytes.
      def input_file_media(part)
        if part.key?("file_id") || part.key?("file_url")
          raise SimpleInference::ValidationError,
                "input_file uses bytes-only ingress, not provider file ids or URLs"
        end

        media = part["file_data"]
        unless media in SimpleInference::MediaInput
          raise SimpleInference::ValidationError,
                "input_file.file_data must carry raw bytes via SimpleInference::MediaInput"
        end
        unless MediaType::FILE_TYPES.include?(media.media_type)
          raise SimpleInference::ValidationError,
                "input_file accepts application/pdf bytes, not #{media.media_type}"
        end

        media
      end

      # OpenAI requires a name beside inline file bytes; the other PDF wires
      # carry only the media type and bytes. The name is metadata, not evidence
      # of the file's type.
      def input_file_filename(part)
        filename = part["filename"].to_s
        if filename.empty?
          raise SimpleInference::ValidationError, "input_file requires a filename"
        end

        filename
      end

      # Split caller options at the request boundary into [declared, extra_body].
      # Declared symbol options are the protocol's request_option_keys; anything
      # else raises, pointing at the escape hatch. extra_body must be a
      # string-keyed Hash — it carries provider-specific WIRE fields verbatim.
      def split_request_options(options)
        opts = Internal::Keys.shallow_symbolize(options)
        extra_body = opts.delete(:extra_body)
        validate_extra_body(extra_body)

        unknown = opts.keys - self.class.request_option_keys
        unless unknown.empty?
          raise SimpleInference::ValidationError,
                "unknown request option(s): #{unknown.join(", ")} " \
                "(#{self.class.name.split("::").last} accepts: #{self.class.request_option_keys.join(", ")}; " \
                "pass provider-specific wire fields via extra_body: {\"field\" => value})"
        end

        [opts, extra_body || {}]
      end

      # extra_body is the caller's boundary: a Hash of string-keyed WIRE
      # fields, verified once here.
      def validate_extra_body(extra_body)
        return if extra_body.nil?

        unless extra_body.is_a?(Hash)
          raise SimpleInference::ValidationError, "extra_body must be a Hash of wire fields"
        end

        return if extra_body.keys.all? { |key| key.is_a?(String) }

        raise SimpleInference::ValidationError,
              "extra_body carries raw WIRE fields and must use string keys (got #{extra_body.keys.inspect})"
      end

      # A registry-declared non-credential marker (the codex originator and
      # lite-marker headers, the image lane's originator): a non-blank
      # String when provided, the lane's frozen default otherwise.
      def validated_marker(key, value, default)
        return default if value.nil?
        return value.to_s unless value.to_s.strip.empty?

        raise SimpleInference::ConfigurationError,
              "#{key} must be a non-blank String (got #{value.inspect})"
      end

      # A registry-declared intake-default flag: true/false when provided,
      # the lane's frozen default otherwise.
      def validated_flag(key, value, default)
        return default if value.nil?
        return value if value == true || value == false

        raise SimpleInference::ConfigurationError,
              "#{key} must be true or false (got #{value.inspect})"
      end

      # Merge extra_body into an already-built string-keyed wire body. A
      # collision with a field the protocol already wrote is a caller error —
      # never silent duplicate JSON keys, never a silent overwrite.
      def merge_extra_body(body, extra_body)
        return body if extra_body.empty?

        collisions = body.keys & extra_body.keys
        unless collisions.empty?
          raise SimpleInference::ValidationError,
                "extra_body field(s) collide with request fields the protocol already builds: #{collisions.join(", ")}"
        end

        body.merge!(extra_body)
      end

      # finalize_wire_body's multipart twin. The JSON seam merges extra_body
      # into a string-keyed body hash; here the body is a PARTS ARRAY, so each
      # extra_body pair becomes one more (non-file) form-field part and a
      # collision is an extra_body key matching an existing part's name — same
      # message, same never-silent semantics.
      def finalize_multipart_parts(parts, extra_body)
        return parts if extra_body.empty?

        collisions = parts.map { |part| part.fetch(:name).to_s } & extra_body.keys
        unless collisions.empty?
          raise SimpleInference::ValidationError,
                "extra_body field(s) collide with request fields the protocol already builds: #{collisions.join(", ")}"
        end

        parts + extra_body.map { |key, value| { name: key, value: value } }
      end

      # One MediaInput as one multipart file part: a streamed input rides
      # its source and declared size, a held one its bytes.
      def multipart_file_part(media, filename:)
        part = { filename: filename, content_type: media.media_type }
        if media.streamed?
          part[:source] = media.source
          part[:byte_size] = media.byte_size
        else
          part[:body] = media.bytes
        end
        part.compact
      end

      # The single seam where a protocol's BUILT body meets the caller's
      # verbatim extra_body: normalize the built side to the wire key type
      # (strings, deep) FIRST so the collision check can never be fooled by a
      # :model-vs-"model" mismatch, then merge. Protocols may build their body
      # with whichever key type reads best internally — this is the one exit.
      def finalize_wire_body(body, extra_body)
        merge_extra_body(Internal::Keys.deep_stringify(body), extra_body)
      end

      # Per-request header hook: protocols whose wire marks requests with
      # headers derived from the BODY being sent (e.g. codex responses-lite)
      # override this. Stateless by construction — no per-request ivars, so
      # protocol instances stay shareable across fibers.
      def wire_headers(_body)
        config.headers
      end

      # Body-derived protocol markers stored beside the compiled payload.
      # Config credentials join only when the compiled request executes.
      def protocol_headers(_body)
        {}
      end

      def compile_json_request(path:, body:, stream:, expect_json: true, &executor)
        validate_url("#{config.base_url}#{path}")
        headers = protocol_headers(body).merge("Content-Type" => "application/json")
        if stream
          headers["Accept"] = "text/event-stream, application/json"
        end

        SimpleInference::CompiledRequest.new(
          http_method: :post,
          path: path,
          headers: headers,
          payload: serialize_json_body(body),
          stream: stream,
          expect_json: expect_json,
          &executor
        )
      end

      def compile_multipart_request(path:, parts:, expect_json: true, &executor)
        validate_url("#{config.base_url}#{path}")
        boundary = "simple-inference-#{SecureRandom.hex(16)}"
        headers = protocol_headers(parts).merge(
          "Content-Type" => "multipart/form-data; boundary=#{boundary}"
        )

        SimpleInference::CompiledRequest.new(
          http_method: :post,
          path: path,
          headers: headers,
          payload: serialize_multipart_body(parts, boundary: boundary),
          stream: false,
          expect_json: expect_json,
          &executor
        )
      end

      # The ONE adapter request envelope: method, absolute URL, headers, the
      # serialized body and the connection's three timeouts.
      def request_env(method:, url:, headers:, body:, connection: config)
        {
          method: method,
          url: url,
          headers: headers,
          body: body,
          timeout: connection.timeout,
          open_timeout: connection.open_timeout,
          read_timeout: connection.read_timeout,
        }
      end

      def compiled_request_env(compiled, connection)
        request_env(
          method: compiled.http_method,
          url: "#{connection.base_url}#{compiled.path}",
          headers: compiled_connection_headers(connection).merge(compiled.headers),
          body: compiled.payload,
          connection: connection,
        )
      end

      # The credential headers a compiled request executes with; lanes whose
      # wire spells the credential differently (x-api-key, x-goog-api-key)
      # override this.
      def compiled_connection_headers(connection)
        connection.headers
      end

      def request_json(method:, url:, headers:, body:, expect_json:, raise_on_http_error:)
        handle_response(
          request_env(
            method: method,
            url: url,
            headers: (headers || {}).merge("Content-Type" => "application/json"),
            body: serialize_json_body(body),
          ),
          expect_json: expect_json,
          raise_on_http_error: raise_on_http_error,
        )
      end

      def validate_url(url)
        raw = url.to_s.strip
        raise SimpleInference::ConfigurationError, "base_url is required" if raw.empty?

        uri = URI.parse(raw)
        unless uri.is_a?(URI::HTTP) && uri.host.to_s != ""
          raise SimpleInference::ConfigurationError, "base_url must be a valid http:// or https:// URL"
        end
      rescue URI::InvalidURIError
        raise SimpleInference::ConfigurationError, "base_url must be a valid http:// or https:// URL"
      end

      def handle_response(request_env, expect_json:, raise_on_http_error:, adapter: @adapter)
        validate_url(request_env[:url])

        envelope = Internal::Envelope.from_h(adapter.call(request_env))
        parse = expect_json.nil? ? envelope.headers.fetch("content-type", "").include?("json") : expect_json
        response = json_response(envelope, parse: parse)
        maybe_raise_http_error(response: response, raise_on_http_error: raise_on_http_error)
        response
      rescue Timeout::Error => e
        raise SimpleInference::TimeoutError, e.message
      rescue SocketError, SystemCallError => e
        raise SimpleInference::ConnectionError, e.message
      end

      # --- The ONE Server-Sent-Events engine (was four near-identical copies:
      # openai_compatible / openai_responses / anthropic_messages /
      # gemini_generate_content each hand-rolled this stack) ---

      # POST a JSON body expecting an SSE stream back. Yields
      # (event_name, parsed_event_hash) per SSE event; event_name is nil when
      # the block carries no `event:` line (the OpenAI families put the type
      # inside the data JSON instead).
      def post_json_stream(path, body, raise_on_http_error: nil, &on_event)
        env = request_env(
          method: :post,
          url: "#{config.base_url}#{path}",
          headers: wire_headers(body).merge(
            "Content-Type" => "application/json",
            "Accept" => "text/event-stream, application/json"
          ),
          body: serialize_json_body(body),
        )

        handle_stream_response(env, raise_on_http_error:, &on_event)
      end

      # Dispatch a stream-shaped request and normalize the THREE response
      # shapes providers actually produce when asked to stream: an incremental
      # SSE stream (chunks parsed as they arrive), a BUFFERED SSE body (adapter
      # without streaming support, or a headerless SSE payload — sniffed via
      # sse_like_body?), and a plain JSON/error response (some gateways ignore
      # Accept; callers decide via raise_on_http_error/streaming_unsupported).
      # Streaming success returns a Response with body: nil.
      def handle_stream_response(request_env, raise_on_http_error: nil, adapter: @adapter, &on_event)
        validate_url(request_env[:url])

        sse_buffer = +""
        sse_done = false
        streamed = false

        raw_response =
          adapter.call_stream(request_env) do |chunk|
            streamed = true
            next if sse_done

            sse_buffer << chunk.to_s
            sse_done = consume_sse_buffer(sse_buffer, &on_event) || sse_done
          end

        envelope = Internal::Envelope.from_h(raw_response)
        body_str = envelope.body.to_s
        content_type = envelope.headers.fetch("content-type", "")

        if envelope.sse? || (envelope.success? && sse_like_body?(body_str))
          consume_sse_buffer(body_str.dup, &on_event) unless streamed
          return Response.new(status: envelope.status, headers: envelope.headers, body: nil, raw_body: body_str)
        end

        response = json_response(envelope, parse: content_type.include?("json") || json_like_body?(body_str))
        maybe_raise_http_error(response:, raise_on_http_error:)
        response
      rescue Timeout::Error => e
        raise SimpleInference::TimeoutError, e.message
      rescue SocketError, SystemCallError => e
        raise SimpleInference::ConnectionError, e.message
      end

      # The parse boundary: `body` is the wire's JSON object or nil (the text
      # is always in raw_body). A non-2xx body that is not a JSON object is
      # left to the HTTP error path rather than raised as a DecodeError.
      def json_response(envelope, parse:)
        body_str = envelope.body.to_s
        body =
          if parse
            begin
              parse_json_object(body_str)
            rescue SimpleInference::DecodeError
              raise if envelope.success?

              nil
            end
          end

        Response.new(status: envelope.status, headers: envelope.headers, body: body, raw_body: body_str)
      end

      # Parse completed SSE blocks out of the mutable buffer and emit each
      # event. Returns true once the OpenAI-family [DONE] sentinel is seen
      # (Anthropic/Gemini streams never emit it, so the early-out is inert for
      # them); the caller then ignores any residual chunks.
      def consume_sse_buffer(buffer, &on_event)
        done = false

        extract_sse_blocks(buffer).each do |block|
          event_name, data = sse_event_and_data_from_block(block)
          next if data.nil?

          payload = data.strip
          next if payload.empty?
          if payload == "[DONE]"
            done = true
            buffer.clear
            break
          end

          on_event&.call(event_name, parse_sse_json_event(payload))
        end

        done
      end

      # Split completed SSE blocks (LF/CRLF separators both appear in the
      # wild) off the FRONT of the buffer, leaving any partial block in place
      # for the next chunk.
      def extract_sse_blocks(buffer)
        blocks = []

        loop do
          idx_lf = buffer.index("\n\n")
          idx_crlf = buffer.index("\r\n\r\n")
          idx = [idx_lf, idx_crlf].compact.min
          break if idx.nil?

          sep_len = (idx == idx_crlf) ? 4 : 2
          blocks << buffer.slice!(0, idx)
          buffer.slice!(0, sep_len)
        end

        blocks
      end

      # One SSE block -> [event_name (or nil), joined data payload (or nil)].
      # Multi-line data fields join with newlines per the SSE spec; comment
      # lines (leading ":") are skipped.
      def sse_event_and_data_from_block(block)
        event_name = nil
        data_lines = []

        block.to_s.split(/\r?\n/).each do |line|
          next if line.nil? || line.empty?
          next if line.start_with?(":")

          if line.start_with?("event:")
            event_name = line[6..]&.strip
          elsif line.start_with?("data:")
            data_lines << (line[5..]&.lstrip).to_s
          end
        end

        [event_name, data_lines.empty? ? nil : data_lines.join("\n")]
      end

      # Sniff an SSE payload that arrived WITHOUT a text/event-stream
      # content-type (seen from proxies that strip or rewrite headers).
      def sse_like_body?(body_str)
        body = body_str.to_s.lstrip
        return false if body.empty?

        (body.start_with?("data:", "event:") || body.include?("\ndata:") || body.include?("\nevent:")) &&
          (body.include?("\n\n") || body.include?("\r\n\r\n"))
      end

      def json_like_body?(body_str)
        body = body_str.to_s.lstrip
        return false if body.empty?

        body.start_with?("{", "[")
      end

      # Every SSE data payload this gem consumes is a JSON object; the gate
      # here is what lets the event readers trust `event["type"]` downstream.
      def parse_sse_json_event(payload)
        parsed = JSON.parse(payload, **json_parse_options)
        unless parsed.is_a?(Hash)
          raise SimpleInference::DecodeError, "SSE JSON event must be a JSON object, got #{parsed.class}"
        end

        parsed
      rescue JSON::ParserError => e
        raise SimpleInference::DecodeError, "Failed to parse SSE JSON event: #{e.message}"
      end

      # The one wire-body parse: a JSON object, or a DecodeError. Every
      # downstream reader digs into the object without re-checking its class.
      def parse_json_object(body)
        parsed = parse_json(body)
        unless parsed.is_a?(Hash)
          raise SimpleInference::DecodeError, "expected a JSON object response body, got #{parsed.class}"
        end

        parsed
      end

      def parse_json(body)
        return nil if body.empty?

        JSON.parse(body, **json_parse_options)
      rescue JSON::ParserError => e
        raise SimpleInference::DecodeError, "Failed to parse JSON response: #{e.message}"
      end

      DEFAULT_JSON_PARSE_OPTIONS = {}.freeze

      # Protocol hook over EVERY wire-body parse this base performs (unary
      # responses and SSE event payloads alike). Lanes whose wire carries
      # decimal amounts that must not round-trip through binary Floats
      # override this (OpenRouter: decimal_class: BigDecimal so usage.cost
      # keeps its exact wire digits).
      def json_parse_options
        DEFAULT_JSON_PARSE_OPTIONS
      end

      def serialize_json_body(body)
        return nil if body.nil?

        JSON.generate(body)
      rescue JSON::GeneratorError, TypeError => e
        raise SimpleInference::ValidationError, "Request body must be JSON serializable: #{e.message}"
      end

      # THE MESSAGE AS SEGMENTS, NEVER AS ONE STRING. Construction normalizes
      # every fixed piece and file source to one emitter contract, so iteration
      # has no type dispatch on the request hot path.
      def serialize_multipart_body(parts, boundary:)
        segments = []
        size = 0
        add = lambda do |chunk|
          segments << ->(&emit) { emit.call(chunk) }
          size += chunk.bytesize
        end

        Array(parts).each do |part|
          name = part.fetch(:name).to_s
          value = part.fetch(:value)

          add.call("--#{boundary}\r\n")
          # A part's value is a scalar form field or a file-part Hash — the
          # caller's declared union at this boundary.
          file_part = Hash.try_convert(value)
          if file_part
            file = normalize_file_part(file_part)
            add.call(
              %(Content-Disposition: form-data; name="#{escape_multipart(name)}"; ) +
              %(filename="#{escape_multipart(file.fetch(:filename))}"\r\n)
            )
            add.call("Content-Type: #{sanitize_multipart_header_value(file.fetch(:content_type))}\r\n\r\n")
            segments << file.fetch(:content)
            size += file.fetch(:byte_size)
          else
            add.call(%(Content-Disposition: form-data; name="#{escape_multipart(name)}"\r\n\r\n))
            add.call(value.to_s)
          end
          add.call("\r\n")
        end
        add.call("--#{boundary}--\r\n")

        SimpleInference::MultipartBody.new(segments, size)
      end

      # TWO FORMS, ONE BOUNDARY. A part carries either the bytes themselves
      # (`:body`) or a `:source` — something that yields chunks when called,
      # paired with the size it will yield. A source is NOT a path: `:path`
      # stays refused because it would let a caller name a file on this
      # machine at the wire boundary, and an in-process reader handed over by
      # trusted code is a different thing entirely.
      def normalize_file_part(value)
        unless value.key?(:body) || value.key?(:source) || value.key?(:path)
          raise SimpleInference::ValidationError,
                "multipart file parts must use symbol keys (:body or :source required, " \
                "got #{value.keys.inspect})"
        end
        if value.key?(:path)
          raise SimpleInference::ValidationError,
                "multipart file parts carry raw bytes via :body — filesystem paths are not accepted"
        end

        content, byte_size = file_part_content(value)

        {
          filename: (value[:filename] || "upload").to_s,
          content_type: (value[:content_type] || "application/octet-stream").to_s,
          content: content,
          byte_size: byte_size,
        }
      end

      def file_part_content(hash)
        source = hash[:source]
        if source.nil?
          body = hash.fetch(:body)
          return [->(&emit) { emit.call(body) }, body.bytesize]
        end

        size = hash[:byte_size]
        if size.nil?
          raise SimpleInference::ValidationError,
                "a multipart file :source must declare its :byte_size — the request cannot " \
                "state a Content-Length it would have to build the body to learn"
        end

        [source, size]
      end

      def escape_multipart(value)
        sanitize_multipart_header_value(value).gsub(/[\"\\]/, "\\\\\\0")
      end

      def sanitize_multipart_header_value(value)
        value.to_s.gsub(/[\r\n]/, " ")
      end

      # Fold the independent switch, effort and summary into the wire object.
      # An explicit off suppresses the effort and its capture/context options;
      # model support and defaults are the consumer's selection policy.
      def nested_reasoning_effort_options(options, default_summary: nil)
        effort = options[:reasoning_effort]
        summary = options[:reasoning_summary]
        explicit = options[:reasoning]
        reasoning = reasoning_option_hash(explicit)
        enabled = validated_reasoning_enabled(options[:reasoning_enabled], effort: effort || reasoning[:effort])
        rest = options.except(:reasoning_enabled, :reasoning_effort, :reasoning_summary, :reasoning)
        return rest if enabled.nil? && effort.nil? && summary.nil? && explicit.nil?

        if enabled == false
          reasoning = reasoning.except(:enabled, :effort, :summary, :context, :max_tokens)
          return rest.merge(reasoning: reasoning.merge(nested_reasoning_enabled_options(false)))
        end

        reasoning = reasoning.merge(nested_reasoning_enabled_options(true)) if enabled == true
        reasoning = reasoning.merge(effort: effort) unless effort.nil?
        summary = default_summary if summary.nil? && default_summary && !effort.nil? && !reasoning.key?(:summary)
        reasoning =
          if summary.to_s.strip == "none"
            reasoning.except(:summary)
          elsif summary.nil?
            reasoning
          else
            reasoning.merge(summary: summary)
          end

        reasoning.empty? ? rest : rest.merge(reasoning: reasoning)
      end

      # Responses uses its native disable effort. Brokers with a real boolean
      # override only this wire spelling, keeping one normalization path.
      def nested_reasoning_enabled_options(enabled)
        enabled ? {} : { effort: "none" }
      end

      def validated_reasoning_enabled(value, effort: nil)
        unless value.nil? || value == true || value == false
          raise SimpleInference::ValidationError, "reasoning_enabled must be true, false, or nil"
        end
        if value == true && effort.to_s == "none"
          raise SimpleInference::ValidationError, "reasoning_enabled true conflicts with reasoning_effort none"
        end
        value
      end

      # A caller-built `reasoning:` enters here once: a Hash (any key spelling)
      # or nil; anything else is the caller's error.
      def reasoning_option_hash(explicit)
        return {} if explicit.nil?

        unless explicit.is_a?(Hash)
          raise SimpleInference::ValidationError,
                "reasoning must be a Hash carrying effort (got #{explicit.inspect})"
        end

        Internal::Keys.shallow_symbolize(explicit)
      end

      def raise_on_http_error?(raise_on_http_error)
        raise_on_http_error.nil? ? config.raise_on_error : !!raise_on_http_error
      end

      def http_error_message(response)
        message = "HTTP #{response.status}"
        error_body = response.body || error_body_from_text(response.raw_body)
        return message if error_body.nil?

        # The wire's `error` is a declared union: an object carrying
        # code/message, or a bare string from OpenAI-compatible gateways.
        case (error = error_body["error"])
        when Hash
          error["message"] || error_body["message"] || message
        else
          error || error_body["message"] || message
        end
      end

      # A body the content-type did not declare as JSON may still carry a
      # JSON error object; anything else yields no message.
      def error_body_from_text(text)
        parse_json_object(text)
      rescue SimpleInference::DecodeError
        nil
      end

      def maybe_raise_http_error(response:, raise_on_http_error:)
        return unless raise_on_http_error?(raise_on_http_error)
        return if response.success?

        raise SimpleInference::HTTPError.new(http_error_message(response), response: response)
      end
    end
  end
end
