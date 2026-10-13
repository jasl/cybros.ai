module SimpleInference
  module Resources
    class Responses
      def initialize(client:)
        @client = client
      end

      def create(model:, input:, **options)
        @client.execute(compile(model: model, input: input, stream: false, **options))
      end

      def stream(model:, input:, **options)
        @client.execute(compile(model: model, input: input, stream: true, **options))
      end

      def compile(model:, input:, stream:, **options)
        input, options = Planning::RequestValidator.validate_responses_request(
          profile: profile, model: model, input: input, options: options, streaming: stream
        )
        compile_from_validated(model: model, input: input, stream: stream, **options)
      end

      def compile_from_validated(model:, input:, stream:, **options)
        if stream
          protocol.compile_stream(model: model, input: input, **options)
        else
          protocol.compile_create(model: model, input: input, **options)
        end
      end

      private

      def profile = @client.execution_profile

      def protocol
        ApiFormat.protocol_for(profile: profile, config: @client.config)
      end
    end
  end
end
