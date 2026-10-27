require_relative "decision_protocol"

module SimpleInference
  module Protocols
    class TypeSafeSystemOne < DecisionProtocol
      private

      def decision_path = "#{config.api_prefix}/systemone"

      def request_body(model, input, questions)
        { "model" => model, "state" => input.value,
          "questions" => questions.entries.to_h { |question| [question.name, wire_question(question)] } }
      end

      def wire_question(question)
        body = { "type" => question.type, "instructions" => question.instructions }
        case question.type
        when "predicate"
          body["type"] = "noul"
        when "choice"
          body["criteria"] = question.choices.to_h do |choice|
            if [true, false].include?(choice.value)
              raise SimpleInference::CapabilityError, "TypeSafe choice values must be strings"
            end
            [choice.value, choice.description]
          end
        when "score"
          body["criteria"] = question.levels.map { |level| [level.label, level.description].reject(&:empty?).join(": ") }
        else
          raise SimpleInference::CapabilityError, "unsupported TypeSafe question type"
        end
        body
      end

      def answer_rows(answers) = answers.to_h

      def normalize_answer(answer, question)
        normalized = case answer.fetch("type")
        when "noul"
          { "type" => "predicate", "probability" => answer.fetch("noul") }
        when "choice"
          answer.merge("probabilities" => answer.fetch("probabilities").map do |value, probability|
            { "value" => value, "probability" => probability }
          end)
        when "score"
          answer.merge("probabilities" => answer.fetch("probabilities").map do |value, probability|
            { "value" => Integer(value, 10), "probability" => probability }
          end)
        else
          raise SimpleInference::DecodeError, "unknown TypeSafe answer type"
        end
        super(normalized, question)
      end
    end
  end
end
