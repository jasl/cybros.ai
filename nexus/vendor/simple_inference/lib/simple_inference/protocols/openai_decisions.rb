require_relative "decision_protocol"

module SimpleInference
  module Protocols
    class OpenAIDecisions < DecisionProtocol
      private

      def decision_path = "#{config.api_prefix}/decisions"

      def request_body(model, input, questions)
        evidence = case input.kind
        when :text then input.value
        when :json
          [{ "role" => "user", "content" => [{ "type" => "input_json", "data" => input.value }] }]
        else
          raise ArgumentError, "unknown decision input kind"
        end
        { "model" => model, "input" => evidence, "questions" => questions.to_a }
      end

      def answer_rows(answers)
        indexed = answers.to_h { |answer| [answer.fetch("name"), answer] }
        unless indexed.length == answers.length
          raise SimpleInference::DecodeError, "decision response has duplicate question names"
        end
        indexed
      end
    end
  end
end
