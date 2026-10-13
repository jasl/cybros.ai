require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationInputStepsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_create_encodes_the_existing_step_dsl_and_preserves_raw_nested_steps
    raw = { "tool" => { "name" => "check", "input" => { "strict" => false, "expected" => nil }, "key" => "check" } }
    steps = CybrosAgent::Steps.build do |s|
      s.parallel do |p|
        p.sequence do |sequence|
          sequence.tool "read_file", input: { "path" => "README.md" }, key: "read"
          sequence.ask "Continue?", key: "confirm"
        end
        p.wait task: "earlier", key: "wait"
      end
    end
    steps << [raw]
    expected = [
      { "parallel" => [
        [{ "tool" => { "name" => "read_file", "input" => { "path" => "README.md" }, "key" => "read" } },
         { "ask" => { "prompt" => "Continue?", "key" => "confirm" } }],
        { "wait" => { "task" => "earlier", "key" => "wait" } },
      ] },
      [raw],
    ]

    accepted = chat([[202, {}, input_with_steps(expected)]]).inputs.create(
      kind: "direct_reply", text: "Inspect the source", steps: steps, idempotency_key: "input-with-steps"
    )

    assert_equal expected, request.fetch(:body).fetch("input").fetch("steps")
    assert_equal expected, accepted.input.steps
    assert_equal expected, accepted.input.to_h.fetch(:steps)
    assert_predicate accepted.input.steps, :frozen?
    assert_predicate accepted.input.steps.last.first.fetch("tool").fetch("input"), :frozen?
    raw.fetch("tool").fetch("input")["strict"] = true
    assert_equal false, accepted.input.steps.last.first.fetch("tool").fetch("input").fetch("strict")
  end

  def test_update_encodes_replacement_steps_beside_the_existing_lock_fence
    steps = CybrosAgent::Steps.build { |s| s.ask "Approve the result?", key: "review" }
    expected = [{ "ask" => { "prompt" => "Approve the result?", "key" => "review" } }]
    fixture = input_with_steps(expected)
    input_id = fixture.fetch("input").fetch("public_id")

    updated = chat([[200, {}, fixture]]).inputs.update(input_id, steps: steps, expected_lock_version: 3)

    assert_equal :patch, request.fetch(:method)
    assert_equal "#{PATH}/inputs/#{input_id}", request.fetch(:path)
    assert_equal({ "steps" => expected, "expected_lock_version" => 3 }, request.fetch(:body).fetch("input"))
    assert_equal expected, updated.steps
  end

  def test_create_and_update_preserve_omission_null_and_an_empty_steps_array
    [{}, { steps: nil }, { steps: [] }].each do |keywords|
      fixture = contract.fetch("valid_input_fixture")
      input_id = fixture.fetch("input").fetch("public_id")
      inputs = chat([[202, {}, fixture], [200, {}, fixture]]).inputs

      inputs.create(text: "Continue", idempotency_key: "steps-presence", **keywords)
      inputs.update(input_id, text: "Revised", **keywords)

      [request, request(1)].each do |sent|
        body = sent.fetch(:body).fetch("input")
        assert_equal keywords.key?(:steps), body.key?("steps")
        assert_equal keywords, body.slice("steps").transform_keys(&:to_sym)
      end
    end
  end

  def test_input_reads_distinguish_missing_steps_from_an_empty_tree
    fixture = contract.fetch("valid_input_fixture")
    omitted = chat([[202, {}, fixture]]).inputs.create(text: "Continue", idempotency_key: "plain").input
    assert_nil omitted.steps
    refute omitted.to_h.key?(:steps)

    empty = chat([[200, {}, input_with_steps([])]]).inputs.update(omitted.public_id, steps: [])
    assert_empty empty.steps
    assert_equal [], empty.to_h.fetch(:steps)
  end

  def test_the_exported_steps_input_projection_round_trips
    fixture = contract.fetch("valid_steps_input_fixture")
    steps = fixture.fetch("input").fetch("steps")

    accepted = chat([[202, {}, fixture]]).inputs.create(text: "Inspect the result",
      steps: steps, idempotency_key: "exported-steps")

    assert_equal steps, accepted.input.steps
    assert_equal steps, accepted.input.to_h.fetch(:steps)
    assert_equal steps, request.fetch(:body).fetch("input").fetch("steps")
  end

  def test_the_original_run_can_replay_the_input_uuid_to_recover_an_ordinary_append_receipt
    steps = CybrosAgent::Steps.build { |s| s.ask "Approve?", key: "hold" }
    run_id = "01900000-0000-7000-8000-0000000000a0"
    fixture = input_with_steps([{ "ask" => { "prompt" => "Approve?", "key" => "hold" } }])
    materialization = contract.fetch("valid_materialization_fixture")
    materialization = { "materialization" => materialization.fetch("materialization").merge("run_public_id" => run_id) }
    receipt = { "receipt" => {
      "accepted_task_keys" => ["hold"], "steps" => ["hold"], "revision" => 2,
      "deliverable_task_key" => "hold", "resolution_tokens" => { "hold" => "resolution-token" }, "replayed" => true,
    } }
    handle = workspace([[202, {}, fixture], [200, {}, materialization], [200, {}, receipt]])
    inputs = handle.conversation(CONVERSATION_ID).inputs

    accepted = inputs.create(text: "Review the result", steps: steps, idempotency_key: "enqueue-review")
    original = inputs.materialization(accepted.public_id)
    appended = handle.run(original.run_public_id).append(steps: steps, idempotency_key: accepted.public_id)

    assert_equal "/agent_api/v1/workspaces/#{WORKSPACE_ID}/runs/#{run_id}/tasks", request(2).fetch(:path)
    assert_equal accepted.public_id, request(2).fetch(:headers).fetch("Idempotency-Key")
    assert_equal request.fetch(:body).fetch("input").fetch("steps"), request(2).fetch(:body).fetch("steps")
    assert_predicate appended, :replayed?
    assert_equal ["hold"], appended.accepted_task_keys
    assert_equal "resolution-token", appended.resolution_tokens.fetch("hold")
    refute accepted.input.to_h.key?(:resolution_tokens)
    refute original.to_h.key?(:resolution_tokens)
  end

  private

    def input_with_steps(steps)
      { "input" => contract.fetch("valid_input_fixture").fetch("input").merge("steps" => steps) }
    end
end
