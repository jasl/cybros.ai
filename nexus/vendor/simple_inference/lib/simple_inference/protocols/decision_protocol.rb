require_relative "base"

module SimpleInference
  module Protocols
    # Both decision wires have one unary response, named questions and the same
    # score scale. Subclasses own only their request and answer spellings.
    class DecisionProtocol < Base
      def self.request_option_keys = %i[questions].freeze

      def create(model:, input:, questions:, **options)
        compile_create(model: model, input: input,
          questions: Decisions::Questions.from_array(questions), **options).execute(config)
      end

      def compile_create(model:, input:, questions:, **options)
        _declared, extra_body = split_request_options(options)
        body = merge_extra_body(request_body(model, Decisions::Input.from_value(input), questions), extra_body)
        compile_json_request(path: decision_path, body: body, stream: false) do |connection_config, compiled|
          response = compiled_response(compiled, config: connection_config)
          result(response, questions)
        end
      end

      private

      def result(response, questions)
        body = response.body.to_h
        answers = answer_rows(body.fetch("answers"))
        expected_names = questions.entries.map(&:name)
        unless answers.keys.sort == expected_names.sort
          raise SimpleInference::DecodeError, "decision answers do not match the requested question names"
        end
        normalized = questions.entries.map { |question| normalize_answer(answers.fetch(question.name), question) }
        Decisions::Result.new(answers: normalized, usage: body["usage"],
          provider_response: response, provider_format: "decisions.create")
      rescue KeyError, TypeError, ArgumentError => error
        raise SimpleInference::DecodeError, "invalid decision response", cause: error
      end

      def normalize_answer(answer, question)
        type = answer.fetch("type")
        return Decisions::Answer.new(name: question.name, type: type) if type == "refusal"

        unless type == question.type
          raise SimpleInference::DecodeError, "decision answer type does not match the question"
        end
        case type
        when "predicate"
          Decisions::Answer.new(name: question.name, type: type, probability: probability(answer.fetch("probability")))
        when "choice"
          values = question.choices.map(&:value)
          choice = answer.fetch("choice")
          raise SimpleInference::DecodeError, "decision returned an unknown choice" unless values.include?(choice)

          Decisions::Answer.new(name: question.name, type: type, choice: choice,
            confidence: probability(answer.fetch("confidence")),
            probabilities: distribution(answer.fetch("probabilities"), values))
        when "score"
          values = question.levels.each_index.to_a
          score = Float(answer.fetch("score"))
          unless score.finite? && (0..values.last).cover?(score)
            raise SimpleInference::DecodeError, "decision score is outside the requested levels"
          end
          probabilities = distribution(answer.fetch("probabilities"), values).map do |entry|
            entry.with(label: question.levels.fetch(entry.value).label)
          end
          Decisions::Answer.new(name: question.name, type: type, score: score,
            confidence: probability(answer.fetch("confidence")), probabilities: probabilities)
        else
          raise SimpleInference::DecodeError, "unknown decision answer type"
        end
      end

      def probability(value)
        normalized = Float(value)
        unless normalized.finite? && (0..1).cover?(normalized)
          raise SimpleInference::DecodeError, "decision probability must be between zero and one"
        end
        normalized
      end

      def distribution(rows, expected_values)
        values = rows.map { |row| row.fetch("value") }
        unless values.length == expected_values.length && (expected_values - values).empty?
          raise SimpleInference::DecodeError, "decision distribution does not match the requested values"
        end
        rows.map do |row|
          Decisions::Probability.new(value: row.fetch("value"), probability: probability(row.fetch("probability")))
        end
      end
    end
  end
end
