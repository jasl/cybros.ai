module SimpleInference
  module Images
    # A normalized provider result. Encoded image payloads stay encoded here;
    # the Active Storage owner is the single decode/size boundary.
    Result = Data.define(:images, :usage, :provider_response, :provider_format, :output_text) do
      def initialize(images:, usage:, provider_response:, provider_format:, output_text: nil)
        super(images: Array(images).freeze, usage:, provider_response:, provider_format:, output_text:)
      end
    end
  end
end
