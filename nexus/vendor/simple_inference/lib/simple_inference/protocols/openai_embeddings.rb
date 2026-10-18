require_relative "base"
require_relative "../measure"

module SimpleInference
  module Protocols
    class OpenAIEmbeddings < Base
      def self.local_safety_limit_option_keys
        { input_byte_cap: "input_bytes" }.freeze
      end

      # The standard OpenAI embeddings options this protocol forwards by name.
      # The input byte cap is a profile-fed construction fact, never a request
      # option; provider-specific wire fields ride extra_body.
      def self.request_option_keys
        %i[dimensions encoding_format user].freeze
      end

      def initialize(embeddings_path: nil, input_byte_cap: nil, **connection)
        super(**connection)
        @embeddings_path = normalize_embeddings_path(embeddings_path || "#{config.api_prefix}/embeddings")
        @input_byte_cap = validated_input_byte_cap(input_byte_cap)
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        declared, extra_body = split_request_options(options)
        enforce_input_byte_cap(input)
        validate_dimensions(declared[:dimensions]) if declared.key?(:dimensions)
        requested_dimension = declared[:dimensions]
        body = request_body(model: model, input: input, declared: declared, extra_body: extra_body)

        compile_json_request(path: @embeddings_path, body: body, stream: false) do |connection_config, compiled|
          response = compiled_response(compiled, config: connection_config)
          embeddings_result_from_response(response, requested_dimension: requested_dimension)
        end
      end

      # The pre-IO measurement seam for the M2 input-byte bound: the summed
      # UTF-8 byte count over the ORDERED text inputs. Non-string entries
      # (e.g. token-id arrays) have no byte-truth text measurement and are a
      # loud rejection here.
      def measured_input_bytes(input)
        ordered_inputs(input).sum { |entry| Measure.utf8_byte_count(entry) }
      end

      private

      def embeddings_result_from_response(response, requested_dimension:)
        body = response.body || {}

        SimpleInference::Embeddings::Result.new(
          embeddings: normalize_embeddings(body["data"]),
          usage: normalize_usage(body["usage"]),
          provider_response: response,
          provider_format: "embeddings.create",
          # requested-vs-effective dimension verification (C2-1) lives in the
          # result value object; the declared dimensions pin rides along.
          requested_dimension: requested_dimension,
        )
      end

      def ordered_inputs(input)
        input.is_a?(Array) ? input : [input]
      end

      def enforce_input_byte_cap(input)
        return if @input_byte_cap.nil?

        Measure.ensure_within(
          value: measured_input_bytes(input),
          cap: @input_byte_cap,
          bound_id: "embeddings_input_bytes",
          unit: "bytes",
        )
      end

      def validated_input_byte_cap(cap)
        valid =
          case cap
          when nil
            return nil
          when Integer
            cap.positive?
          else
            false
          end
        return cap if valid

        raise SimpleInference::ConfigurationError,
              "input_byte_cap must be a positive Integer input cap (got #{cap.inspect})"
      end

      # dimensions passes through bound to evidence; nonsense values never
      # reach the wire.
      def validate_dimensions(value)
        return if value.is_a?(Integer) && value.positive?

        raise SimpleInference::ValidationError,
              "dimensions must be a positive Integer (got #{value.inspect})"
      end

      # The wire body, STRING-keyed throughout — each wire field written in
      # exactly one place; declared options map 1:1 onto same-named fields.
      def request_body(model:, input:, declared:, extra_body:)
        body = { "model" => model, "input" => input }
        declared.each { |key, value| body[key.to_s] = value }
        merge_extra_body(body, extra_body)
      end

      def normalize_embeddings(data)
        Array(data).map do |item|
          {
            "index" => item["index"],
            "embedding" => item["embedding"],
            "raw" => item,
          }.compact
        end
      end

      # Truthful usage per the non-text matrix: this route reports Chat-style
      # names ({prompt_tokens, total_tokens}, live-probed 2026-08-09), so the
      # canonical input_tokens mapping is added ALONGSIDE the preserved raw
      # fields. Absent stays absent — an omitted usage object stays nil and
      # nothing is fabricated as 0.
      def normalize_usage(value)
        return nil if value.nil?
        return value if value.key?("input_tokens") || !value.key?("prompt_tokens")

        value.merge("input_tokens" => value["prompt_tokens"])
      end

      def normalize_embeddings_path(value)
        path = value.to_s.strip
        path = "#{config.api_prefix}/embeddings" if path.empty?
        path = "/#{path}" unless path.start_with?("/")

        prefix = config.api_prefix.to_s
        return path if prefix.empty? || path.start_with?("#{prefix}/") || path == prefix
        return path unless config.base_url_included_api_prefix?

        "#{prefix}#{path}"
      end
    end
  end
end
