module SimpleInference
  module Embeddings
    # The normalized embeddings and the request dimension, when one was
    # pinned. The parser already owns the entry shape; this value verifies a
    # requested dimension without copying each entry or adding a duplicate
    # `dimension` member beside `embedding.length`.
    Result = Data.define(:embeddings, :usage, :provider_response, :provider_format, :requested_dimension) do
      def initialize(embeddings:, usage:, provider_response:, provider_format:, requested_dimension: nil)
        embeddings = Array(embeddings).freeze
        embeddings.each { |entry| verify_requested_dimension(entry["embedding"], requested_dimension) }
        super(embeddings:, usage:, provider_response:, provider_format:, requested_dimension:)
      end

      private

      def verify_requested_dimension(vector, requested_dimension)
        return if requested_dimension.nil? || vector.nil? || vector.length == requested_dimension

        raise SimpleInference::DecodeError,
              "requested dimension #{requested_dimension} but the response returned " \
              "#{vector.length} values — requested-vs-effective dimension verification failed"
      end
    end
  end
end
