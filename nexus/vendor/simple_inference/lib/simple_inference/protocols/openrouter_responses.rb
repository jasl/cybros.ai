require "bigdecimal"

require_relative "openai_compatible_responses"

module SimpleInference
  module Protocols
    # The audited openrouter_chat lane (adapter_profile `openrouter_chat`,
    # route `chat_completions_http_sse`).
    #
    # Wire contract beyond the generic chat-completions family:
    # - every request carries the frozen provider block
    #   {require_parameters: true} and the X-OpenRouter-Metadata: enabled
    #   header,
    # - usage accounting is always-on server-side; the deprecated
    #   stream_options.include_usage no-op is never emitted,
    # - decimal usage values retain their exact wire precision in the ordinary
    #   usage hash, and reasoning_details ride the assistant message so a
    #   subsequent turn can echo them back.
    class OpenRouterResponses < OpenAICompatibleResponses
      def self.protocol_option_keys = superclass.protocol_option_keys
      # The :exacto discipline (owner ruling 2026-08-14): the broker routes
      # within the model's :exacto quality-sorted pool, and the variant rides
      # the model string itself (the registry model_pin). Every request still
      # carries this provider block, so an endpoint that would drop a
      # parameter can never serve the lane.
      PROVIDER_BLOCK = { "require_parameters" => true }.freeze

      METADATA_HEADERS = { "X-OpenRouter-Metadata" => "enabled" }.freeze

      # usage.cost / usage.cost_details.* are decimal CREDIT amounts: parsed
      # as binary Floats they silently lose wire digits
      # (0.123456789012345684 -> 0.12345678901234568 — an undercount path).
      # Every JSON parse on this lane (unary bodies AND SSE event payloads)
      # therefore decodes decimals as BigDecimal, exactly as written.
      JSON_PARSE_OPTIONS = { decimal_class: BigDecimal }.freeze

      # The parent's protocol_option_keys (stream_include_usage) are
      # deliberately INHERITED (post-Stage-4 re-audit, fix 2): the always-on
      # usage fact is a registry fact — every openrouter row declares
      # wire_options { stream_include_usage: false } — not an override that
      # empties the parent's construction vocabulary. Construction without
      # that fact refuses below rather than silently emitting the deprecated
      # opt-in.
      def initialize(stream_include_usage: nil, **connection)
        super(stream_include_usage:, **connection)
        return unless stream_include_usage?

        raise SimpleInference::ConfigurationError,
              "openrouter must be constructed with stream_include_usage: false (the registry " \
              "rows declare it): usage accounting is always-on for this broker and the " \
              "deprecated stream_options.include_usage opt-in must never be emitted"
      end

      # OpenRouter nests effort into its `reasoning` wire object; the
      # reasoning/reasoning_summary companions are read by that mapping
      # (nested_reasoning_effort_options), so they are surface options here.
      #
      # :stream_options is REMOVED from the inherited vocabulary (register
      # fact, not configuration): usage accounting is always-on for this
      # broker and the lane must never emit the deprecated
      # stream_options.include_usage opt-in — a caller-supplied
      # stream_options is a loud unknown-option rejection, never a silent
      # pass-through onto the wire.
      def self.request_option_keys
        (superclass.request_option_keys - %i[stream_options] + %i[reasoning reasoning_summary]).freeze
      end

      private

      def json_parse_options = JSON_PARSE_OPTIONS

      def protocol_headers(_body)
        METADATA_HEADERS
      end

      def wire_headers(body)
        config.headers.merge(protocol_headers(body))
      end

      # Both chat-option builders audit their OUTPUT for stream_options too:
      # the vocabulary removal above rejects the caller spelling, and this
      # guard keeps inherited translation drift (a superclass injecting the
      # field) from ever reaching this lane's wire.
      def chat_options(options)
        pinned = super
        reject_stream_options(pinned.merge(provider: PROVIDER_BLOCK))
      end

      def reasoning_chat_options(options)
        nested_reasoning_effort_options(options)
      end

      def nested_reasoning_enabled_options(enabled)
        { enabled: enabled }
      end

      def stream_chat_options(options)
        reject_stream_options(super)
      end

      def reject_stream_options(options)
        return options unless options.key?(:stream_options) || options.key?("stream_options")

        raise SimpleInference::ValidationError,
              "openrouter requests never carry stream_options: usage accounting is always-on " \
              "for this broker and the deprecated stream_options.include_usage opt-in must " \
              "never be emitted"
      end

      # --- terminal observation (create body + stream chunks) ---

      # The reasoning_details blocks this lane echoes back on the assistant
      # message, collected across chunks or read off the terminal body.
      class WireObservation
        attr_reader :reasoning_details

        def initialize
          @reasoning_details = []
        end

        def collect(details) = @reasoning_details.concat(Array(details))
      end

      def new_wire_observation
        WireObservation.new
      end

      def observe_stream_event(observation, event)
        observation.collect(event.dig("choices", 0, "delta", "reasoning_details"))
      end

      def observe_terminal_body(observation, body)
        observation.collect(body.dig("choices", 0, "message", "reasoning_details")) unless body.nil?
      end

      def synthesized_message_extras(observation)
        details = observation.reasoning_details
        return {} if details.empty?

        # Echo-back contract: consecutive reasoning_details blocks must ride
        # the assistant message unmodified so later turns can replay them.
        { "reasoning_details" => details }
      end
    end
  end
end
