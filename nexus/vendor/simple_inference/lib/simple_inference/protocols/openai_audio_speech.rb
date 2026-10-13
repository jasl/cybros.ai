require_relative "base"
require_relative "../measure"

module SimpleInference
  module Protocols
    class OpenAIAudioSpeech < Base
      # The dual pre-IO input bound (C2-1 non-text matrix, enforced with
      # SimpleInference::Measure before any request body or IO exists):
      # - Unicode scalars: the Create Speech API's character bound (frozen
      #   conservative Nexus metric: Unicode scalar-value count);
      # - UTF-8 bytes: the conservative token proxy for the model-page token
      #   bound — byte-level BPE consumes at least one byte per token, so
      #   bytes bound tokens from above; scalar counts do NOT.
      #
      # The cap VALUES live in the registry row's `local_safety_limits`
      # (input_characters: 4_096, input_bytes: 2_000 — the single home;
      # post-Stage-4 re-audit, fix 1b) and arrive here as construction
      # options via ApiFormat.protocol_for. This protocol keeps only
      # the enforcement: a bound it was not fed is not enforced here (the
      # openai_embeddings pattern).
      def self.local_safety_limit_option_keys
        { input_character_cap: "input_characters", input_byte_cap: "input_bytes" }.freeze
      end

      # The standard OpenAI speech options this protocol forwards by name
      # (stream_format is deliberately absent — this protocol's contract is one
      # binary audio body, not SSE); voice/response_format pass through as
      # declared options (selectable-VALUE gating is manifest-side).
      # provider-specific wire fields ride extra_body.
      def self.request_option_keys
        %i[instructions response_format speed].freeze
      end

      def initialize(speech_path: nil, input_character_cap: nil, input_byte_cap: nil, **connection)
        super(**connection)
        @speech_path = normalize_speech_path(speech_path || "#{config.api_prefix}/audio/speech")
        @input_character_cap = validated_input_cap(:input_character_cap, input_character_cap)
        @input_byte_cap = validated_input_cap(:input_byte_cap, input_byte_cap)
      end

      def create(model:, input:, voice:, **options)
        compile_create(model: model, input: input, voice: voice, **options).execute(config)
      end

      def compile_create(model:, input:, voice:, **options)
        reject_language_option(options)
        declared, extra_body = split_request_options(options)
        enforce_input_bounds(input)
        body = finalize_wire_body(request_body(model: model, input: input, voice: voice, declared: declared), extra_body)

        compile_json_request(path: @speech_path, body: body, stream: false, expect_json: false) do |connection_config, compiled|
          speech_result_from_response(compiled_response(compiled, config: connection_config))
        end
      end

      private

      def speech_result_from_response(response)
        SimpleInference::Audio::SpeechResult.new(
          audio: response.raw_body,
          mime_type: response.headers["content-type"] || "application/octet-stream",
          provider_response: response,
          provider_format: "audio.speech",
        )
      end

      # M2's speech language is a LOCAL rejection, not an escape-hatch
      # candidate: the Create Speech route exposes no such request field
      # (register speech bullet), so the option can never lower onto this wire.
      def reject_language_option(options)
        return unless options.key?(:language) || options.key?("language")

        raise SimpleInference::ValidationError,
              "language is locally rejected: the Create Speech route exposes no language request field"
      end

      # A construction-fed pre-IO cap: positive Integer when present; nil
      # means the bound was not fed (direct construction outside the
      # registry) and is not enforced here.
      def validated_input_cap(key, cap)
        return nil if cap.nil?
        return cap if cap.is_a?(Integer) && cap.positive?

        raise SimpleInference::ConfigurationError,
              "#{key} must be a positive Integer input cap (got #{cap.inspect})"
      end

      # The zero-IO preflight for both registry-declared input bounds. The
      # scalar bound is checked first so an input over BOTH caps names the
      # character bound; at the shipped values the byte proxy is the
      # effective ceiling (any input at 4,096 scalars necessarily carries at
      # least 4,096 bytes) — both bounds stay enforced by requirement.
      def enforce_input_bounds(input)
        unless @input_character_cap.nil?
          Measure.ensure_within(
            value: Measure.unicode_scalar_count(input),
            cap: @input_character_cap,
            bound_id: "speech_input_characters",
            unit: "characters",
          )
        end
        return if @input_byte_cap.nil?

        Measure.ensure_within(
          value: Measure.utf8_byte_count(input),
          cap: @input_byte_cap,
          bound_id: "speech_input_bytes_token_proxy",
          unit: "bytes",
        )
      end

      # The wire body, STRING-keyed throughout — each wire field written in
      # exactly one place; declared options map 1:1 onto same-named fields.
      def request_body(model:, input:, voice:, declared:)
        body = { "model" => model, "input" => input, "voice" => voice }
        declared.each { |key, value| body[key.to_s] = value }
        body
      end

      def normalize_speech_path(value)
        path = value.to_s.strip
        path = "#{config.api_prefix}/audio/speech" if path.empty?
        path = "/#{path}" unless path.start_with?("/")

        prefix = config.api_prefix.to_s
        return path if prefix.empty? || path.start_with?("#{prefix}/") || path == prefix
        return path unless config.base_url_included_api_prefix?

        "#{prefix}#{path}"
      end
    end
  end
end
