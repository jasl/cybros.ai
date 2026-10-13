require_relative "../media_type"

module SimpleInference
  class ExecutionProfile
    # What a lane declares about one input modality: the byte-truth MIME
    # allowlist, the long-edge cap the preparation step reduces an
    # occurrence to (`max_dimension` — it changes the bytes sent), and an
    # optional per-occurrence `token_cost` that is meaningful only together
    # with that preparation cap.
    class InputMediaFacts < Data.define(:mime_allowlist, :max_dimension, :token_cost)
      def self.from_h(modality, hash) = Facts.ingest(self, hash, label: "input_media[#{modality}]", modality: modality)

      def initialize(mime_allowlist:, max_dimension: nil, token_cost: nil, modality: "modality")
        label = "input_media[#{modality}]"
        unless mime_allowlist.is_a?(Array) && !mime_allowlist.empty?
          raise SimpleInference::ConfigurationError, "#{label}.mime_allowlist must be a non-empty Array"
        end

        unknown_types = mime_allowlist.map(&:to_s) - MediaType::KNOWN_TYPES
        unless unknown_types.empty?
          raise SimpleInference::ConfigurationError,
                "#{label}.mime_allowlist contains unknown media type(s): #{unknown_types.join(", ")}"
        end

        max_dimension = Facts.positive_integer(max_dimension, field: "#{label}.max_dimension") unless max_dimension.nil?
        token_cost = Facts.positive_integer(token_cost, field: "#{label}.token_cost") unless token_cost.nil?
        if token_cost && max_dimension.nil?
          raise SimpleInference::ConfigurationError,
                "#{label}.token_cost needs a max_dimension: a token bound is only true because the " \
                "preparation bound makes it true"
        end

        super(mime_allowlist: mime_allowlist.map { |type| -type.to_s }.freeze, max_dimension:, token_cost:)
      end

      def to_h = super.transform_keys(&:to_s).compact
    end
  end
end
