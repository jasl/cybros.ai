module SimpleInference
  module Resources
    class Images
      def initialize(client:)
        @client = client
      end

      def generate(model:, prompt: nil, input: nil, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?
        raise SimpleInference::ValidationError, "prompt or input is required" if prompt.to_s.strip.empty? && input.nil?

        options = Planning::RequestValidator.validate_images_request(
          profile: profile, model: model, options: options
        )
        @client.execute(compile_from_validated(model: model, prompt: prompt, input: input, **options))
      end

      def compile_from_validated(model:, prompt: nil, input: nil, **options)
        protocol.compile_create(model: model, prompt: prompt, input: input, **options)
      end

      private

      def profile = @client.execution_profile

      def protocol
        ApiFormat.protocol_for(profile: profile, config: @client.config)
      end
    end
  end
end
