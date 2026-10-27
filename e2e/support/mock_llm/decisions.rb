module E2E
  module MockLLM
    # Synthetic evidence maps question names to values. Reading the actual input
    # and question criteria makes lost structured input observable end to end.
    module Decisions
      private

        def decisions(env, system_one:)
          body = json_body(env)
          model = body.fetch("model")
          expected_model = system_one ? "mock-system-one" : "mock-decision"
          return unknown_model(model) unless model == expected_model

          if system_one
            state = body.fetch("state")
            questions = body.fetch("questions")
          else
            part = body.fetch("input").fetch(0).fetch("content").fetch(0)
            raise Directives::Invalid, "expected input_json evidence" unless part.fetch("type") == "input_json"

            state = part.fetch("data")
            questions = body.fetch("questions").to_h { |question| [question.fetch("name"), question] }
          end
          answers = questions.to_h do |name, question|
            [name, decision_answer(question, state.fetch(name), system_one:)]
          end
          unless system_one
            answers = answers.map { |name, answer| answer.merge("name" => name) }
          end
          input_tokens, output_tokens = system_one ? [43, 7] : [41, 0]
          json_response(200, { "answers" => answers,
            "usage" => { "input_tokens" => input_tokens, "output_tokens" => output_tokens,
                         "total_tokens" => input_tokens + output_tokens } })
        end

        def decision_answer(question, value, system_one:)
          type = question.fetch("type")
          case type
          when "predicate", "noul"
            { "type" => type, (system_one ? "noul" : "probability") => (value ? 1.0 : 0.0) }
          when "choice"
            choices = system_one ? question.fetch("criteria").keys : question.fetch("choices").map { |choice| choice.fetch("value") }
            probabilities = choices.map { |choice| { "value" => choice, "probability" => choice == value ? 1.0 : 0.0 } }
            { "type" => type, "choice" => value, "confidence" => 1.0,
              "probabilities" => decision_distribution(probabilities, system_one:) }
          when "score"
            levels = system_one ? question.fetch("criteria") : question.fetch("levels")
            # Fractional scores prove callers preserve numbers rather than selecting a level.
            probabilities = levels.each_index.map do |index|
              { "value" => index, "probability" => [1.0 - (index - value).abs, 0.0].max }
            end
            { "type" => type, "score" => value, "confidence" => 0.75,
              "probabilities" => decision_distribution(probabilities, system_one:) }
          else
            raise Directives::Invalid, "unsupported decision question"
          end
        end

        def decision_distribution(rows, system_one:)
          if system_one
            rows.to_h { |row| [row.fetch("value").to_s, row.fetch("probability")] }
          else
            rows
          end
        end
    end
  end
end
