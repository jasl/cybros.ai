require_relative "base"

module SimpleInference
  module Protocols
    # Gemini embeddings v1: the singular embedContent route (one text per call).
    #
    # Wire shape (live-probed 2026-08-09):
    #   POST /v1beta/models/{model}:embedContent
    #   { content: { parts: [{ text }] }, outputDimensionality? }
    #   -> { embedding: { values: [...] } }   (NO usage on the wire)
    class GeminiEmbeddings < Base
      # HOW MANY TEXTS THE ROUTE CARRIES, declared rather than inferred. The
      # singular `embedContent` endpoint takes exactly one, and a caller who
      # asked for five must be told so where they can still fix it — so this
      # is read by acceptance as well as by request compilation, the same way
      # ACCEPTED_ROLES is. A lane that declares nothing is unbounded.
      MAX_INPUT_TEXTS = 1

      # The MRL dimensions contract from the pinned embeddings guide:
      # 128..3072, default 3072 when unspecified.
      OUTPUT_DIMENSIONALITY_RANGE = (128..3_072)

      # The register row's token input bound, enforced through the frozen
      # conservative byte proxy (owner ruling 2026-08-10: token counting
      # stays conservative — every tokenizer consumes at least one input
      # byte per token, so an equal byte cap can never under-enforce the
      # token bound). The cap VALUE lives in the registry row's
      # `local_safety_limits` (input_bytes: 2_048 — the single home;
      # post-Stage-4 re-audit, fix 1b) and arrives here as a construction
      # option via ApiFormat.protocol_for; this protocol keeps only
      # the enforcement. This stable id names the bound in typed errors:
      INPUT_BYTE_BOUND_ID = "gemini_embeddings_input_bytes_token_proxy".freeze

      def self.local_safety_limit_option_keys
        { input_byte_cap: "input_bytes" }.freeze
      end

      def initialize(input_byte_cap: nil, **connection)
        super(**connection)
        unless input_byte_cap.nil? || (input_byte_cap.is_a?(Integer) && input_byte_cap.positive?)
          raise SimpleInference::ConfigurationError,
                "input_byte_cap must be a positive Integer input cap (got #{input_byte_cap.inspect})"
        end
        @input_byte_cap = input_byte_cap
      end

      # :dimensions is the portable spelling, :output_dimensionality the
      # native one — both map onto the request's outputDimensionality.
      # taskType/title are NOT declared options in v1 (the probe-evidenced
      # body is exactly {content, outputDimensionality?}); an unevidenced
      # native field rides extra_body visibly or not at all.
      def self.request_option_keys
        %i[dimensions output_dimensionality].freeze
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        text = ensure_single_text_input(input)
        enforce_input_byte_cap(text)
        requested_dimensionality = resolve_output_dimensionality(declared)
        body = finalize_wire_body(request_body(text: text, requested_dimensionality: requested_dimensionality), extra_body)

        compile_json_request(path: embed_content_path(model), body: body, stream: false) do |connection_config, compiled|
          response = compiled_response(compiled, config: connection_config)
          embeddings_result_from_response(
            response,
            requested_dimensionality: requested_dimensionality,
          )
        end
      end

      private

      def embeddings_result_from_response(response, requested_dimensionality:)
        body = response.body || {}

        SimpleInference::Embeddings::Result.new(
          embeddings: response.success? ? normalized_embedding(body) : [],
          # embedContent reports NO usage on the wire (settled by probe AND
          # released SDK): usage is truthfully missing, never fabricated from
          # stray metadata.
          usage: nil,
          provider_response: response,
          provider_format: "embeddings.embed_content",
          # requested-vs-effective dimension verification (C2-1) lives in the
          # result value object — one seam for every embeddings lane.
          requested_dimension: requested_dimensionality,
        )
      end

      # Enforcement only: a nil cap means the bound was not fed (direct
      # construction outside the registry) and is not enforced here — the
      # openai_embeddings pattern.
      def enforce_input_byte_cap(text)
        return if @input_byte_cap.nil?

        SimpleInference::Measure.ensure_within(
          value: SimpleInference::Measure.utf8_byte_count(text),
          cap: @input_byte_cap,
          bound_id: INPUT_BYTE_BOUND_ID,
          unit: "bytes"
        )
      end

      def embed_content_path(model)
        "/v1beta/models/#{model}:embedContent"
      end

      def gemini_headers(connection_config)
        connection_config.authentication_headers(default: "x-goog-api-key")
      end

      def compiled_connection_headers(connection_config)
        gemini_headers(connection_config)
      end

      # The singular route takes exactly one text per call, so an Array is a
      # shape error against this route and rejects before any IO.
      def ensure_single_text_input(input)
        if input.is_a?(Array)
          raise SimpleInference::ValidationError,
                "gemini embeddings v1 embedContent takes exactly one input text per call " \
                "(got an Array of #{input.length}) — send one String per call"
        end
        unless input.is_a?(String)
          raise SimpleInference::ValidationError,
                "input must be a single text String (got #{input.class})"
        end
        raise SimpleInference::ValidationError, "input text is required" if input.strip.empty?

        input
      end

      def resolve_output_dimensionality(declared)
        native = declared[:output_dimensionality]
        portable = declared[:dimensions]
        if !native.nil? && !portable.nil? && native != portable
          raise SimpleInference::ValidationError,
                "dimensions (#{portable.inspect}) and output_dimensionality (#{native.inspect}) disagree — " \
                "both spellings map onto the same outputDimensionality wire field"
        end

        value = native.nil? ? portable : native
        return nil if value.nil?

        unless value.is_a?(Integer) && OUTPUT_DIMENSIONALITY_RANGE.cover?(value)
          raise SimpleInference::ValidationError,
                "outputDimensionality must be an Integer in #{OUTPUT_DIMENSIONALITY_RANGE.min}..#{OUTPUT_DIMENSIONALITY_RANGE.max} " \
                "(MRL contract; got #{value.inspect})"
        end

        value
      end

      # The probe-evidenced wire body, STRING-keyed: {content, outputDimensionality?}.
      # Model rides the path on the singular route, never the body.
      def request_body(text:, requested_dimensionality:)
        body = { "content" => { "parts" => [{ "text" => text }] } }
        body["outputDimensionality"] = requested_dimensionality unless requested_dimensionality.nil?
        body
      end

      # A 2xx response MUST carry embedding.values. The requested-vs-effective
      # dimension verification moved into Embeddings::Result (C2-1) — one
      # seam for every embeddings lane, not a per-protocol copy.
      def normalized_embedding(body)
        values = body.dig("embedding", "values")
        unless values.is_a?(Array)
          raise SimpleInference::DecodeError,
                "embedContent response carries no embedding.values array (deterministically malformed body)"
        end

        [{ "index" => 0, "embedding" => values, "raw" => body["embedding"] }]
      end
    end
  end
end
