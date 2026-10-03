require_relative "openai_responses"

module SimpleInference
  module Protocols
    # xAI Responses lane (`POST /v1/responses`, OpenAI-Responses-shaped wire).
    #
    # Register-frozen lane pins (conformance register, xAI rows):
    # - `store: false` on EVERY request — never omitted, never true. xAI's
    #   route is stateful by default (30-day retention); the Nexus profile is
    #   stateless by pin, so a caller-provided `store: true` is a loud local
    #   rejection, not a silent override.
    # - Stateless continuation is the typed predecessor edge: request
    #   `include: ["reasoning.encrypted_content"]` and replay reasoning items
    #   (with `encrypted_content`) in `input`. `previous_response_id` /
    #   `conversation` are NOT the continuation mechanism (the lane has no
    #   conversation_state capability) and are rejected in both the declared
    #   vocabulary and the extra_body escape hatch.
    # - `reasoning_effort` is the SDK-typed model-agnostic closed set
    #   `none|low|medium|high`, lowered verbatim into `reasoning.effort`;
    #   an out-of-set value rejects locally with zero outbound IO.
    # - Media ingress is bytes-only (the inherited Responses-family lowering
    #   builds the data-URL from verified bytes); `detail` is a field of the
    #   wire's `input_image` part and lowers verbatim like every other field.
    # - Usage on the pinned raw route is TERMINAL-ONLY (inherited parsing
    #   already reads usage from `response.completed` / terminal bodies
    #   only) and passes through provider-shaped and verbatim:
    #   `usage.cost_in_usd_ticks` stays a lossless integer (native cost
    #   evidence, scale 1 USD = 10^10 ticks — never converted to a currency),
    #   and a field absent on the wire (e.g. the docs-only
    #   `cost_in_nano_usd`) stays absent.
    # - The probe-observed SSE set exceeds the documented list
    #   (`response.reasoning_summary_part.added/.done`,
    #   `response.reasoning_summary_text.done`); unrecognized non-error events
    #   remain internal and do not interrupt result assembly.
    class XAIResponses < OpenAIResponses
      # The SDK-facing WIRE GATE (register: the SDK-typed model-agnostic
      # closed set) — every effort spelling this wire accepts. The format's
      # defaults (`ApiFormat.defaults("xai_responses")[:reasoning_options]`)
      # declare a DIFFERENT fact with a different job: the reviewed efforts a
      # catalog model under this format may offer at selection, which may
      # narrow this set but never exceed it.
      # `xhigh` entered 2026-08-21 from the vendor's own model page (Grok 4.6
      # "supports four effort levels: xhigh, high (default), medium, and
      # low"). `none` is KEPT and unverified: the docs enumerate what is
      # supported, not what is rejected, and dropping a spelling that may
      # work is a louder failure than admitting one that may not.
      REASONING_EFFORTS = %w[none low medium high xhigh].freeze
      ENCRYPTED_REASONING_INCLUDE = "reasoning.encrypted_content".freeze

      # Server-side conversation-state fields excluded from the declared
      # vocabulary AND refused via extra_body: this lane's only continuation
      # mechanism is encrypted-reasoning replay.
      STATEFUL_CONTINUATION_KEYS = %w[previous_response_id conversation].freeze

      def self.request_option_keys
        (superclass.request_option_keys - STATEFUL_CONTINUATION_KEYS.map(&:to_sym)).freeze
      end

      private

      # Single choke point: create/stream/responses_* all lower through here
      # (same seam CodexResponses uses), AFTER the inherited
      # normalization (reasoning nesting, tool wire shape, response_format),
      # so every exit path carries the lane pins.
      def responses_request_options(options)
        body = super
        validate_reasoning_effort(body[:reasoning])
        pin_stateless_store(body)
        body
      end

      # The one exit where built body meets the caller's verbatim extra_body:
      # refuse the stateful-continuation spellings there too, so the escape
      # hatch cannot smuggle a conversation-state field past the vocabulary.
      def finalize_wire_body(body, extra_body)
        stateful = extra_body.keys & STATEFUL_CONTINUATION_KEYS
        unless stateful.empty?
          raise SimpleInference::ValidationError,
                "xai_responses has no conversation_state capability: #{stateful.join(", ")} is not the " \
                "continuation mechanism — replay reasoning items with encrypted_content in input instead"
        end

        super
      end

      def validate_reasoning_effort(reasoning)
        effort = reasoning&.dig(:effort)
        return if effort.nil?
        return if REASONING_EFFORTS.include?(effort.to_s)

        raise SimpleInference::ValidationError,
              "xai_responses reasoning effort #{effort.inspect} is not in the frozen SDK-typed set " \
              "(#{REASONING_EFFORTS.join(", ")}); values are lowered verbatim, never normalized"
      end

      # store:false pinned on every request. A caller-provided true (or any
      # non-false value) is a loud rejection — fail-closed, no silent
      # override; an explicit false merely matches the pin.
      def pin_stateless_store(body)
        if body.key?(:store) && body[:store] != false
          raise SimpleInference::ValidationError,
                "xai_responses is stateless by pin: store:false is sent on every request " \
                "(got store: #{body[:store].inspect} — omit it or pass false)"
        end

        body[:store] = false
        includes = Array(body[:include]).map(&:to_s)
        body[:include] = (includes + [ENCRYPTED_REASONING_INCLUDE]).uniq
        nil
      end
    end
  end
end
