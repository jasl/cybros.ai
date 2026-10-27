require "test_helper"
require "json"

class TestDecisions < Minitest::Test
  class Adapter < SimpleInference::HTTPAdapter
    attr_reader :requests
    attr_accessor :body

    def initialize(body)
      @body = body
      @requests = []
    end

    def call(request)
      @requests << request
      { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(body) }
    end
  end

  def questions
    [
      { name: "matches", type: "predicate", instructions: "Does it match?" },
      { name: "category", type: "choice", instructions: "Choose a category.",
        choices: [{ value: "a", description: "First" }, { value: "b", description: "Second" }] },
      { name: "rating", type: "score", instructions: "Rate it.",
        levels: [{ label: "low", description: "Weak" }, { label: "high", description: "Strong" }] },
    ]
  end

  def openai_body
    {
      "answers" => [
        { "name" => "matches", "type" => "predicate", "probability" => 0.8 },
        { "name" => "category", "type" => "choice", "choice" => "b", "confidence" => 0.7,
          "probabilities" => [{ "value" => "a", "probability" => 0.2 }, { "value" => "b", "probability" => 0.8 }] },
        { "name" => "rating", "type" => "score", "score" => 0.75, "confidence" => 0.6,
          "probabilities" => [{ "value" => 0, "label" => "low", "probability" => 0.25 },
                              { "value" => 1, "label" => "high", "probability" => 0.75 }] },
      ],
      "usage" => { "input_tokens" => 100, "output_tokens" => 0, "input_tokens_details" => { "cached_tokens" => 20 } },
    }
  end

  def typesafe_body
    {
      "answers" => {
        "matches" => { "type" => "noul", "noul" => 0.8 },
        "category" => { "type" => "choice", "choice" => "b", "confidence" => 0.7,
          "probabilities" => { "a" => 0.2, "b" => 0.8 } },
        "rating" => { "type" => "score", "score" => 0.75, "confidence" => 0.6,
          "legend" => { "0" => "low: Weak", "1" => "high: Strong" },
          "probabilities" => { "0" => 0.25, "1" => 0.75 } },
      },
      "usage" => { "input_tokens" => 90, "output_tokens" => 12, "cost" => 0.001 },
    }
  end

  def client(format, adapter)
    SimpleInference::Client.new(execution_profile: profile_for(format), adapter: adapter,
      base_url: "https://example.test/api/v1", api_key: "synthetic")
  end

  def test_openai_prepared_request_and_structured_result
    adapter = Adapter.new(openai_body)
    result = client("openai_decisions", adapter).decisions.create(model: "test-model", input: "Evidence", questions: questions)
    request = adapter.requests.fetch(0)
    assert_equal "/api/v1/decisions", URI(request.fetch(:url)).path
    assert_equal({ "model" => "test-model", "input" => "Evidence",
      "questions" => SimpleInference::Decisions::Questions.from_array(questions).to_a }, JSON.parse(request.fetch(:body)))
    assert_equal 0.8, result.answers[0].probability
    assert_equal "b", result.answers[1].choice
    assert_equal 0.75, result.answers[2].score
    assert_equal "high", result.answers[2].probabilities[1].label
    assert_equal openai_body.fetch("usage"), result.usage
  end

  def test_typesafe_prepared_request_normalizes_to_same_answer_contract
    adapter = Adapter.new(typesafe_body)
    result = client("typesafe_system_one", adapter).decisions.create(model: "test-model", input: "Evidence", questions: questions)
    request = adapter.requests.fetch(0)
    assert_equal "/api/v1/systemone", URI(request.fetch(:url)).path
    body = JSON.parse(request.fetch(:body))
    assert_equal "Evidence", body.fetch("state")
    assert_equal({ "type" => "noul", "instructions" => "Does it match?" }, body.fetch("questions").fetch("matches"))
    assert_equal({ "a" => "First", "b" => "Second" }, body.fetch("questions").fetch("category").fetch("criteria"))
    assert_equal ["low: Weak", "high: Strong"], body.fetch("questions").fetch("rating").fetch("criteria")
    expected = client("openai_decisions", Adapter.new(openai_body)).decisions.create(model: "test-model", input: "Evidence", questions: questions)
    assert_equal expected.answers, result.answers
    assert_equal typesafe_body.fetch("usage"), result.usage
  end

  def test_json_evidence_keeps_its_structure_on_both_wires
    evidence = { "ticket" => { "paid" => false, "amount" => 12 }, "items" => [1, 2] }
    %w[openai_decisions typesafe_system_one].each do |format|
      adapter = Adapter.new(format == "openai_decisions" ? openai_body : typesafe_body)
      client(format, adapter).decisions.create(model: "test-model", input: evidence, questions: questions)
      body = JSON.parse(adapter.requests.fetch(0).fetch(:body))
      actual = format == "openai_decisions" ? body.fetch("input").fetch(0).fetch("content").fetch(0).fetch("data") : body.fetch("state")
      assert_equal evidence, actual
    end
  end

  def test_refusal_is_one_question_answer_and_does_not_discard_other_answers_or_usage
    body = openai_body
    body["answers"][1] = { "name" => "category", "type" => "refusal" }
    body["answers"].reverse!
    result = client("openai_decisions", Adapter.new(body)).decisions.create(model: "test-model", input: "Evidence", questions: questions)
    assert_equal %w[matches category rating], result.answers.map(&:name)
    assert_equal({ "name" => "category", "type" => "refusal" }, result.answers[1].to_h)
    assert_equal 0, result.usage.fetch("output_tokens")
  end

  def test_missing_usage_stays_unknown
    body = openai_body.except("usage")
    result = client("openai_decisions", Adapter.new(body)).decisions.create(model: "test-model", input: "Evidence", questions: questions)
    assert_nil result.usage
  end

  def test_wrong_profile_or_model_refuses_before_io
    adapter = Adapter.new(openai_body)
    assert_raises(SimpleInference::CapabilityError) do
      client("openai_responses", adapter).decisions.create(model: "test-model", input: "x", questions: questions)
    end
    assert_raises(SimpleInference::CapabilityError) do
      client("openai_decisions", adapter).decisions.create(model: "other", input: "x", questions: questions)
    end
    assert_empty adapter.requests
  end

  def test_duplicate_names_and_unsupported_types_refuse_before_io
    adapter = Adapter.new(openai_body)
    invalid = [questions.first, questions.first]
    assert_raises(SimpleInference::ValidationError) do
      client("openai_decisions", adapter).decisions.create(model: "test-model", input: "x", questions: invalid)
    end
    assert_raises(SimpleInference::CapabilityError) do
      client("openai_decisions", adapter).decisions.create(model: "test-model", input: "x",
        questions: [{ name: "box", type: "box", instructions: "Find it" }])
    end
    assert_empty adapter.requests
  end

  def test_provider_answer_must_match_questions_and_probability_bounds
    changes = [
      ->(body) { body["answers"].pop },
      ->(body) { body["answers"][0]["probability"] = 1.1 },
      ->(body) { body["answers"][2]["score"] = 2 },
      ->(body) { body["answers"][1]["choice"] = "unknown" },
      ->(body) { body["answers"][2]["probabilities"].pop },
    ]
    changes.each do |change|
      body = openai_body
      change.call(body)
      assert_raises(SimpleInference::DecodeError) do
        client("openai_decisions", Adapter.new(body)).decisions.create(model: "test-model", input: "x", questions: questions)
      end
    end
  end

  def test_typesafe_does_not_silently_stringify_boolean_choices
    adapter = Adapter.new(typesafe_body)
    boolean_question = questions[1].merge(choices: [{ value: true }, { value: false }])
    assert_raises(SimpleInference::CapabilityError) do
      client("typesafe_system_one", adapter).decisions.create(model: "test-model", input: "x", questions: [boolean_question])
    end
    assert_empty adapter.requests
  end
end
