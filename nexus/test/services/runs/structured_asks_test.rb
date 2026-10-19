require "test_helper"
require_relative "../../test_helpers/awaits_test_helper"

class Runs::StructuredAsksTest < ActiveJob::TestCase
  include AwaitsTestHelper

  FIELDS = [
    { "name" => "enabled", "label" => "Enable", "type" => "boolean", "required" => true },
    { "name" => "count", "label" => "Count", "type" => "integer", "required" => true },
  ].freeze

  test "typed answers survive reload and release the existing model continuation" do
    run = seed(ask("gate", "fields" => FIELDS), model("after", "results" => ["gate"]))
    start!(run)
    gate = node(run, "gate")
    assert_equal FIELDS.map { |field| field.fetch("name") }, gate.reload.ask_fields.map(&:name)

    [{ "enabled" => "false", "count" => 0 }, { "enabled" => false },
     { "enabled" => false, "count" => "0" }].each do |answer|
      result = Runs::Parks::Settle.call(node: gate, claim_token: gate.resolution_token, answer: answer)
      assert_equal :invalid_ask_answer, result.outcome
      assert_equal "dispatched", gate.reload.status
      assert_nil gate.content_bodies.find_by(role: "output")
    end

    answer = { "enabled" => false, "count" => 0 }
    result = Runs::Parks::Settle.call(node: gate, claim_token: gate.resolution_token, answer: answer)
    assert_predicate result, :applied?
    assert_equal "completed", gate.reload.status
    body = gate.content_bodies.find_by!(role: "output")
    assert_equal answer, JSON.parse(body.effective_text)
    schedule_loop!(run)
    build(attempt_of(run, "after"))
    assert_includes round_request_entries(node(run, "after")).to_json, '\\"enabled\\":false'
  end

  test "field definitions reject malformed values before creating tasks" do
    invalid = [[], {}, [FIELDS.first, FIELDS.first], [FIELDS.first.merge("required" => "true")],
      [FIELDS.first.merge("label" => 1)], [FIELDS.first.merge("name" => false)],
      [FIELDS.first.merge("unexpected" => 1)], [FIELDS.first.merge("type" => "object")],
      [FIELDS.first.merge("options" => ["yes"])],
      [{ "name" => "x", "label" => "X", "type" => "choice", "options" => ["a", "a"] }]]
    invalid.each do |fields|
      result = create_loop(ask("invalid", "fields" => fields))
      refute_predicate result, :created?, fields.inspect
      assert_includes result.errors.map { |error| error.fetch("code") }, "invalid_ask_fields"
    end
    assert_nil Tasks::AskField.refusal(FIELDS)
  end

  test "optional absence and empty values are distinct from null and invalid choices" do
    fields = [
      { "name" => "text", "label" => "Text", "type" => "string", "required" => true },
      { "name" => "choice", "label" => "Choice", "type" => "choice", "options" => %w[a b] },
      { "name" => "choices", "label" => "Choices", "type" => "multichoice", "options" => %w[a b] },
      { "name" => "number", "label" => "Number", "type" => "number" },
    ].map { |field| Tasks::AskField.new(field) }
    assert_nil Tasks::AskField.answer_refusal(fields, { "text" => "" })
    assert_nil Tasks::AskField.answer_refusal(fields, { "text" => "", "choices" => [], "number" => 0.5 })
    [{}, { "text" => nil }, { "text" => "", "choice" => "c" },
     { "text" => "", "choices" => ["a", "a"] }, { "text" => "", "choices" => [1] },
     { "text" => "", "unknown" => true }].each do |answer|
      assert_equal :invalid_ask_answer, Tasks::AskField.answer_refusal(fields, answer)
    end
  end

  test "structured asks refuse text or conflicting answers and preserve failed resolution" do
    run = seed(ask("gate", "fields" => FIELDS))
    start!(run)
    gate = node(run, "gate")
    answer = { "enabled" => false, "count" => 0 }
    [{ content: "false, 0" }, { answer: answer, content: "true, 10" },
     { answer: nil, answer_present: true }, { answer: answer, structured_content: {} }].each do |payload|
      result = Runs::Parks::Settle.call(node: gate, claim_token: gate.resolution_token, **payload)
      assert_equal :invalid_ask_answer, result.outcome
      assert_equal "dispatched", gate.reload.status
    end
    result = Runs::Parks::Settle.call(node: gate, claim_token: gate.resolution_token,
      outcome: "failed", content: "Cannot answer")
    assert_predicate result, :applied?
    assert_equal "failed", gate.reload.status
    assert_equal "Cannot answer", gate.error_detail
  end

  test "deadline and terminal outcomes precede answer validation" do
    run = seed(ask("gate", "fields" => FIELDS))
    start!(run)
    gate = node(run, "gate")
    gate.update_columns(await_started_at: 25.hours.ago)
    result = Runs::Parks::Settle.call(node: gate, claim_token: gate.resolution_token, answer: {})
    assert_predicate result, :applied?
    assert_equal "timed_out", gate.reload.status
    assert_nil gate.content_bodies.find_by(role: "output")
    assert_predicate Runs::Parks::Settle.call(node: gate, answer: false), :settled?
    assert_equal "timed_out", gate.reload.status
  end

  test "atomic append refuses an invalid answer without adding its steps" do
    run = seed(ask("gate", "fields" => FIELDS))
    start!(run)
    submit = ->(answer) do
      Runs::Tasks::Append.call(Runs::Tasks::Append::Command.authored(
        run: run, steps: [model("after", "results" => ["gate"])],
        resolves: [{ "task" => "gate", "answer" => answer }], creator: @human))
    end
    result = submit.call({ "enabled" => "false", "count" => 0 })
    refute_predicate result, :applied?
    assert_equal ["gate"], run.tasks.pluck(:node_key)
    assert_equal "dispatched", node(run, "gate").status
    assert_predicate submit.call({ "enabled" => false, "count" => 0 }), :applied?
    assert_equal "completed", node(run, "gate").status
    assert run.tasks.exists?(node_key: "after")
  end

  test "schema and answer bounds retain the existing task on refusal" do
    too_many = 33.times.map { |index| FIELDS.first.merge("name" => "field_#{index}") }
    [too_many, [FIELDS.first.merge("label" => "x" * 65_537)]].each do |fields|
      result = create_loop(ask("gate", "fields" => fields))
      refute_predicate result, :created?
      assert_includes result.errors.map { |error| error.fetch("code") }, "invalid_ask_fields"
    end
    refute_predicate create_loop(ask("gate", "fields" => FIELDS, "options" => ["x"])), :created?
    run = seed(ask("gate", "fields" => [{ "name" => "text", "label" => "Text", "type" => "string" }]))
    start!(run)
    gate = node(run, "gate")
    result = Runs::Parks::Settle.call(node: gate, claim_token: gate.resolution_token,
      answer: { "text" => "x" * 1_048_576 })
    assert_equal :result_too_large, result.outcome
    assert_equal "dispatched", gate.reload.status
    assert_nil gate.content_bodies.find_by(role: "output")
  end
end
