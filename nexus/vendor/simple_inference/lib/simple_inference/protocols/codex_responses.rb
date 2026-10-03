require "etc"

require_relative "openai_responses"

module SimpleInference
  module Protocols
    # Codex subscription backend (register `codex_responses.usage.v1`):
    # POST /responses at the backend root, SSE streaming, OAuth Bearer
    # credentials.
    #
    # Frozen header contract (codex-rs pin 883af106):
    #   - `Authorization: Bearer <access token>` and `ChatGPT-Account-ID` are
    #     CREDENTIAL-derived (P11): they arrive via Config headers and merge
    #     only at execution — never through protocol_headers.
    #   - `originator: codex_cli_rs`, the responses-lite marker and
    #     `x-codex-routing-hint: model=<slug>[;tier=<tier>]` (body-derived,
    #     core/src/client.rs build_routing_hint_header) are the non-credential
    #     protocol markers emitted here.
    #   - `User-Agent: codex_cli_rs/<version> (<os> <release>; <arch>)` is
    #     this lane's connection default (login/src/auth/default_client.rs
    #     get_codex_user_agent): a bare HTTP-client UA beside the originator
    #     is the inconsistency; a caller's Config `User-Agent` wins.
    #   - `session-id` / `thread-id` / `x-client-request-id` are the
    #     CONSUMER's per-invocation Config headers (codex-api/src/endpoint/
    #     responses.rs): their values are the cache key and the request id
    #     the consumer derives, so they merge from Config headers at
    #     execution alongside the credential pair, never from the body.
    #
    # The Responses-Lite reshape is CONSTRUCTION-driven: the registry profile
    # carries wire_options.use_responses_lite and ApiFormat.protocol_for
    # forwards it as a protocol option. Model-name regex dispatch is dead —
    # behavior switches read profile facts only. The lite body construction
    # itself mirrors codex-rs build_responses_request at the audited pin.
    class CodexResponses < OpenAIResponses
      CODEX_TERMINAL_EVENT_TYPES = {
        "response.done" => "response.completed".freeze,
        "response.completed" => "response.completed".freeze,
      }.freeze

      # Direct-construction DEFAULTS for the registry-declared construction
      # facts (post-Stage-4 re-audit, fix 2): the codex rows' wire_options
      # declare originator/responses_lite_header (and the intake defaults
      # below) and ApiFormat.protocol_for feeds them; these constants
      # keep the same values for a lane built without a profile.
      RESPONSES_LITE_HEADER = "x-openai-internal-codex-responses-lite".freeze
      ORIGINATOR_HEADER = "originator".freeze
      ORIGINATOR = "codex_cli_rs".freeze
      ROUTING_HINT_HEADER = "x-codex-routing-hint".freeze

      # The pinned codex release this lane's User-Agent claims (the nearest
      # rust-v tag by date at codex-rs 883af106, 2026-09-15). The os/arch
      # tail follows get_codex_user_agent's `(<os> <version>; <arch>)`.
      CODEX_VERSION = "0.155.0".freeze
      USER_AGENT_HEADER = "User-Agent".freeze
      USER_AGENT = begin
        uname = Etc.uname
        "#{ORIGINATOR}/#{CODEX_VERSION} (#{uname[:sysname]} #{uname[:release]}; #{uname[:machine]})".freeze
      end

      # The Responses-Lite function namespace (codex-rs protocol/src/
      # tool_name.rs DEFAULT_FUNCTION_NAMESPACE): every function/custom spec
      # folds into one namespace item of this name.
      FUNCTION_NAMESPACE = "functions".freeze
      NAMESPACED_TOOL_TYPES = %w[function custom].freeze

      # Entitlement/usage-limit classification token: the SSE path matches
      # error.code == "usage_not_included" inside response.failed, the
      # non-SSE bridge matches error.error_type == "usage_not_included" on
      # HTTP 429 (codex-rs sse/responses.rs + api_bridge.rs). Both raise the
      # same typed failure; neither is ever a successful missing-usage marker.
      USAGE_NOT_INCLUDED = "usage_not_included".freeze

      # Typed entitlement/usage-limit failure. Subclasses the parent's
      # response.failed surface so wire usage evidence (when present) rides
      # the same fields; `code` carries the classification token for both the
      # SSE and HTTP-429 variants.
      class UsageNotIncludedError < OpenAIResponses::ResponseFailedError; end

      # The parent vocabulary minus max_output_tokens: the pinned codex-rs
      # request struct never carries it, and the register's request-control
      # inventory forbids silent omission — the declared spelling is a loud
      # zero-IO rejection (extra_body stays the caller's verbatim escape
      # hatch for explicit wire fields).
      def self.request_option_keys
        (OpenAIResponses.request_option_keys - [:max_output_tokens]).freeze
      end

      # Codex markers carry a family DEFAULT when a row omits them (the
      # OpenRouter always-on-usage fact, by contrast, fail-closes without its
      # row value): the adapter owns its originator/lite-marker/store defaults
      # and a row need only override to diverge. Codex serves /responses at
      # the backend root, NOT under /v1.
      def initialize(responses_path: nil, use_responses_lite: nil, originator: nil, responses_lite_header: nil,
                     default_store: nil, encrypted_reasoning_include: nil, **connection)
        super(responses_path: responses_path || "/responses", **connection)
        # Fail-closed: only the literal profile fact `true` enables lite.
        @use_responses_lite = use_responses_lite == true
        @originator = validated_marker(:originator, originator, ORIGINATOR)
        @responses_lite_header = validated_marker(:responses_lite_header, responses_lite_header, RESPONSES_LITE_HEADER)
        @default_store = validated_flag(:default_store, default_store, false)
        @encrypted_reasoning_include = validated_flag(:encrypted_reasoning_include, encrypted_reasoning_include, true)
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def stream(model:, input:, **options)
        compile_stream(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        compile_responses_request(
          model: model, input: normalize_input(input), stream: true,
          return_stream: false, options: options
        )
      end

      def compile_stream(model:, input:, **options)
        compile_responses_request(
          model: model, input: normalize_input(input), stream: true,
          return_stream: true, options: options
        )
      end

      def responses_stream(**params)
        super(**params) do |event|
          yield normalize_codex_event(event)
        end
      end

      private

      def use_responses_lite?
        @use_responses_lite
      end

      # The encrypted-reasoning capture IS the registry-declared
      # `encrypted_reasoning_include` fact, routed through the parent seam so
      # a `false` row actually suppresses the include. codex_request_defaults
      # gates its own include-add on the flag, but the parent's
      # apply_reasoning_capture_defaults re-added it unconditionally
      # (closing re-audit review) — the same wire decision in two homes, and
      # the false spelling silently lied. Shipped rows declare true, and the
      # repeated add remains idempotent because the list is deduplicated.
      def reasoning_capture_defaults?
        @encrypted_reasoning_include
      end

      # Single choke point every path flows through (create/stream wrappers,
      # responses_create, direct responses_stream): codex intake defaults
      # first, then the parent
      # normalization (reasoning nesting, tool wire normalization,
      # response_format mapping), then media lowering, then — under the lite
      # profile flag — the lite reshape over the exact field values classic
      # mode would have sent.
      def responses_request_options(options)
        body = super(codex_request_defaults(options))
        body[:input] = lower_input_media_items(body[:input]) if body[:input].is_a?(Array)
        return body unless use_responses_lite?

        apply_responses_lite(body)
      end

      # Codex intake defaults (idempotent; keys are symbols after
      # split_request_options): store defaulted to the registry-declared
      # pin (default_store, shipped false) unless the caller decided,
      # include:["reasoning.encrypted_content"] only when the profile
      # declares encrypted_reasoning_include and the request carries
      # reasoning (codex-rs client.rs sends no include otherwise), and
      # blank instructions OMITTED like codex's serde skip
      # (`skip_serializing_if = "String::is_empty"`, codex-api/src/common.rs)
      # — no filler sentence is ever written here; lite's developer message
      # is conditional on caller text for the same reason.
      def codex_request_defaults(options)
        request = options.dup
        request[:store] = @default_store unless request.key?(:store)
        if @encrypted_reasoning_include && !request.key?(:include) && codex_reasoning_requested?(request)
          request[:include] = ["reasoning.encrypted_content"]
        end
        request.delete(:instructions) if request[:instructions].to_s.strip.empty?
        request
      end

      # The NON-credential protocol markers: originator always, the lite
      # marker under the profile flag — both registry-declared construction
      # facts on the codex rows — and the body-derived routing hint
      # (`model=<slug>` plus `;tier=<t>` when a service tier is SENT; the
      # codex protocol IS the codex backend, codex's uses_codex_backend
      # gate). Credential-derived headers (Bearer, ChatGPT-Account-ID)
      # merge from Config only at execution.
      def protocol_headers(body)
        headers = { ORIGINATOR_HEADER => @originator }
        headers[@responses_lite_header] = "true" if use_responses_lite?
        hint = routing_hint(body)
        headers[ROUTING_HINT_HEADER] = hint unless hint.nil?
        headers
      end

      def routing_hint(body)
        return nil unless body.is_a?(Hash)

        model = item_field(body, "model").to_s
        return nil if model.empty?

        tier = item_field(body, "service_tier").to_s
        tier.empty? ? "model=#{model}" : "model=#{model};tier=#{tier}"
      end

      def wire_headers(body)
        codex_connection_headers(config).merge(protocol_headers(body))
      end

      # The lane's connection default UNDER the consumer's Config headers:
      # a caller-pinned User-Agent survives, an unpinned one gets the codex
      # spelling instead of the HTTP client's.
      def compiled_connection_headers(connection)
        codex_connection_headers(connection)
      end

      def codex_connection_headers(connection)
        { USER_AGENT_HEADER => USER_AGENT }.merge(connection.headers)
      end

      # Mirror of codex-rs build_responses_request in lite mode:
      # - top-level instructions/tools are omitted entirely
      # - input is prefixed with [additional_tools item, developer message]
      #   (the additional_tools item is unconditional — empty array without
      #   tools; the developer instructions message is conditional on text)
      # - function/custom specs fold into the `functions` namespace
      #   (create_tools_json_for_responses_lite, namespace_tools on by default)
      # - parallel_tool_calls is forced false
      # - reasoning.context = "all_turns" rides an EXISTING reasoning object
      # - image `detail` fields are stripped from input items
      # No uuid-v5 item ids on the two prefix items: they serve retry/resume
      # identity on an incremental/WebSocket path this gem does not have.
      def apply_responses_lite(body)
        lite = body.dup
        instructions = lite.delete(:instructions).to_s
        tools = lite.delete(:tools)

        prefix = [{ type: "additional_tools", role: "developer", tools: namespaced_lite_tools(Array(tools)) }]
        unless instructions.empty?
          prefix << {
            type: "message",
            role: "developer",
            content: [{ type: "input_text", text: instructions }],
          }
        end

        lite[:input] = prefix + normalize_input(lite[:input]).map { |item| strip_image_detail(item) }
        lite[:parallel_tool_calls] = false

        # The reasoning hash is symbol-keyed by contract here:
        # nested_reasoning_effort_options symbolizes caller-provided keys.
        # WP8 wire truth (HTTP 400): the Lite marker requires
        # reasoning.context to be "all_turns" UNCONDITIONALLY — the object is
        # created when absent, and a caller-set different context is a loud
        # local rejection instead of a guaranteed provider 400.
        reasoning = lite[:reasoning] || {}
        context = reasoning[:context]
        if !context.nil? && context != "all_turns"
          raise SimpleInference::ValidationError,
                "the Codex Responses-Lite wire requires reasoning.context \"all_turns\" " \
                "(got #{context.inspect}); the marker header and any other context cannot ride together"
        end
        lite[:reasoning] = reasoning.merge(context: "all_turns")

        lite
      end

      # codex-rs tools/src/tool_spec.rs create_tools_json_for_responses_lite:
      # every function/custom spec folds, in order, into ONE
      # `{type: namespace, name: functions, description: "", tools: [...]}`
      # placed at the index of the first such entry; a caller-supplied
      # `functions` namespace merges into it (its tools appended, a non-blank
      # description wins); every other spec stays in place; the namespace is
      # inserted only when it holds a tool. Tools arrive string-keyed from
      # the parent's responses_wire_tools.
      def namespaced_lite_tools(tools)
        namespace = { "type" => "namespace", "name" => FUNCTION_NAMESPACE, "description" => "", "tools" => [] }
        namespace_index = nil
        folded = []

        tools.each do |tool|
          type = item_field(tool, "type").to_s
          if NAMESPACED_TOOL_TYPES.include?(type)
            namespace = namespace.merge("tools" => namespace["tools"] + [tool])
          elsif type == "namespace" && item_field(tool, "name").to_s == FUNCTION_NAMESPACE
            namespace = merged_function_namespace(namespace, tool)
          else
            folded << tool
            next
          end
          namespace_index ||= folded.length
        end

        return folded if namespace_index.nil? || namespace["tools"].empty?

        folded.dup.insert(namespace_index, namespace)
      end

      def merged_function_namespace(namespace, tool)
        description = item_field(tool, "description").to_s
        merged = namespace.merge("tools" => namespace["tools"] + Array(item_field(tool, "tools")))
        description.strip.empty? ? merged : merged.merge("description" => description)
      end

      MEDIA_BEARING_ITEM_TYPES = [
        "message".freeze,
        "function_call_output".freeze,
        "custom_tool_call_output".freeze,
      ].freeze

      # Codex owns its bytes-only choke point below; opt out of the parent's
      # lowering so the two never run back-to-back (the second pass would see
      # the already-lowered data URL as a caller string and reject it).
      def bytes_only_input_media_lane?
        false
      end

      # Media ingress is BYTES-ONLY (transport policy, register Input-media
      # profiles v1): an input_image part carries a SimpleInference::MediaInput
      # and lowers to the inline base64 data-URL wire form here. Caller data
      # URIs, remote URLs, host paths, and provider file handles are loud
      # rejections at this lowering — never forwarded.
      def lower_input_media_items(items)
        items.map { |item| lower_input_media_item(item) }
      end

      def lower_input_media_item(item)
        return item unless media_bearing_item?(item)

        item.to_h do |key, value|
          next [key, value] unless value.is_a?(Array) && %w[content output].include?(key.to_s)

          [key, value.map { |part| lower_input_media_part(part) }]
        end
      end

      def lower_input_media_part(part)
        return part unless item_field(part, "type").to_s == "input_image"

        media = item_field(part, "image_url")
        unless media.is_a?(SimpleInference::MediaInput)
          raise SimpleInference::ValidationError,
                "codex input_image parts carry raw bytes via SimpleInference::MediaInput — " \
                "caller data URIs, URLs, paths, and provider file handles are rejected at " \
                "this lane's lowering (got #{media.class})"
        end

        rest = part.reject { |key, _value| %w[type image_url].include?(key.to_s) }
        Internal::Keys.deep_stringify(rest).merge(
          "type" => "input_image",
          "image_url" => "data:#{media.media_type};base64,#{[media.bytes].pack("m0")}",
        )
      end

      # Reads a part/item field under either key spelling (kernel snapshots
      # are string-keyed, SDK callers may pass symbols) so a media carrier
      # can never slip past the rejection on a key-type technicality.
      def item_field(hash, name)
        hash.key?(name) ? hash[name] : hash[name.to_sym]
      end

      # Responses also accepts a role/content message without an explicit
      # type, which is the kernel's compiled message shape.
      def media_bearing_item?(item)
        type = item_field(item, "type").to_s
        MEDIA_BEARING_ITEM_TYPES.include?(type) || (type.empty? && !item_field(item, "role").to_s.empty?)
      end

      # codex-rs client_common.rs strip_image_details: remove the `detail`
      # field from input_image parts of messages and tool-output items; every
      # other item variant passes through untouched. Runs after media
      # lowering, so lowered parts are string-keyed here.
      def strip_image_detail(item)
        return item unless media_bearing_item?(item)

        stripped = item.to_h do |key, value|
          next [key, value] unless value.is_a?(Array) && %w[content output].include?(key.to_s)

          [key, value.map { |part| strip_image_part_detail(part) }]
        end
        stripped == item ? item : stripped
      end

      def strip_image_part_detail(part)
        return part unless item_field(part, "type").to_s == "input_image"

        part.reject { |key, _value| key.to_s == "detail" }
      end

      def codex_reasoning_requested?(declared)
        %i[reasoning reasoning_effort reasoning_summary].any? { |key| declared.key?(key) }
      end

      def normalize_input(input)
        return input if input.is_a?(Array)

        [
          {
            type: "message",
            role: "user",
            content: [
              {
                type: "input_text",
                text: input.to_s,
              },
            ],
          },
        ]
      end

      # Terminal normalization only: the empirically pinned response.done /
      # status "done" variants map onto the canonical response.completed
      # vocabulary. response.failed and response.incomplete pass through to
      # the PARENT terminal handling — incomplete is a success terminal
      # (status kept, incomplete_details.reason distinct, usage retained;
      # the old local raise destroyed usage) and failed raises typed below.
      def normalized_stream_event(event)
        normalize_codex_event(event)
      end

      def normalize_codex_event(event)
        normalized_type = CODEX_TERMINAL_EVENT_TYPES[event["type"].to_s]
        return event unless normalized_type

        response = event["response"]
        event.merge(
          "type" => normalized_type,
          "response" => response&.merge("status" => normalize_codex_status(response["status"])),
        )
      end

      def normalize_codex_status(status)
        case status.to_s
        when "done"
          "completed"
        else
          status
        end
      end

      # SSE variant of the entitlement classification: error.code ==
      # "usage_not_included" inside response.failed raises the typed
      # UsageNotIncludedError (wire usage retained when present, per the
      # parent's failed-terminal evidence contract); every other failure
      # defers to the parent's ResponseFailedError.
      def raise_on_failed_stream_event(event)
        return super unless event["type"].to_s == "response.failed"

        response = event["response"] || {}
        error = response["error"] || {}
        return super unless error["code"].to_s == USAGE_NOT_INCLUDED

        usage = response["usage"]
        message = "Codex entitlement/usage-limit failure: #{USAGE_NOT_INCLUDED}"
        message = "#{message} - #{error["message"]}" unless error["message"].to_s.empty?
        raise UsageNotIncludedError.new(
          message,
          code: USAGE_NOT_INCLUDED,
          error_message: error["message"],
          usage: usage,
          response_body: response
        )
      end

      # HTTP-429 variant (non-SSE bridge): error.error_type ==
      # "usage_not_included" classifies as the same typed failure instead of
      # a generic HTTPError. No usage is fabricated for this variant — the
      # 429 body carries none.
      def maybe_raise_http_error(response:, raise_on_http_error:)
        if raise_on_http_error?(raise_on_http_error) && (error = usage_not_included_http_error(response))
          message = "Codex entitlement/usage-limit failure: HTTP 429 #{USAGE_NOT_INCLUDED}"
          message = "#{message} - #{error["message"]}" unless error["message"].to_s.empty?
          raise UsageNotIncludedError.new(
            message,
            code: USAGE_NOT_INCLUDED,
            error_message: error["message"],
            usage: nil,
            response_body: response.body
          )
        end

        super
      end

      def usage_not_included_http_error(response)
        return nil unless response.status == 429 && response.body

        error = response.body["error"] || response.body
        error["error_type"].to_s == USAGE_NOT_INCLUDED ? error : nil
      end
    end
  end
end
