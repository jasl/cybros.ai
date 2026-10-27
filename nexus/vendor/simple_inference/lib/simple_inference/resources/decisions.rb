module SimpleInference
  module Resources
    class Decisions
      def initialize(client:)
        @client = client
      end

      def create(model:, input:, questions:, **options)
        validated = Planning::RequestValidator.validate_decisions_request(
          profile: @client.execution_profile, model: model, questions: questions, options: options
        )
        @client.execute(compile_from_validated(model: model, input: input, **validated))
      end

      def compile_from_validated(model:, input:, questions:, **options)
        protocol = ApiFormat.protocol_for(profile: @client.execution_profile, config: @client.config)
        protocol.compile_create(model: model, input: input, questions: questions, **options)
      end
    end
  end
end
