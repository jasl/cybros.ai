module SimpleInference
  module Resources
    class Embeddings
      def initialize(client:)
        @client = client
      end

      def create(model:, input:, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?
        raise SimpleInference::ValidationError, "input is required" if blank_input?(input)

        options = Planning::RequestValidator.validate_embeddings_request(
          profile: profile, model: model, options: options
        )
        @client.execute(compile_from_validated(model: model, input: input, **options))
      end

      def compile_from_validated(model:, input:, **options)
        protocol.compile_create(model: model, input: input, **options)
      end

      private

      def profile = @client.execution_profile

      def protocol
        ApiFormat.protocol_for(profile: profile, config: @client.config)
      end

      def blank_input?(input)
        case input
        when nil
          true
        when String
          input.strip.empty?
        when Array
          input.empty?
        else
          false
        end
      end
    end
  end
end
