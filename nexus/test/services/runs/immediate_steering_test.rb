require "test_helper"
require_relative "../../test_helpers/runs_round_driver_test_helper"

class Runs::ImmediateSteeringTest < ActiveJob::TestCase
  include RunsRoundDriverTestHelper

  def steer_fixture
    run = seed(model("ask", "prompt" => "Run both tasks and report."))
    start!(run)
    run_step!(run, sse_success("calling", tool_calls: calls("short", "long")), key: "ask")
    tokens = %w[r1t0 r1t1].to_h do |key|
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        run: run, task_key: key, executor: suite_runner
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.inspect
      [key, claimed.value.claim_token]
    end
    [run, tokens]
  end

  def commit_claimed_tool(run, tokens, key, text)
    committed = Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: key, executor: suite_runner, claim_token: tokens.fetch(key),
      content: text, structured_content: nil, result_type: nil, outcome: "completed",
      is_error: false, title: nil, metadata: nil
    ))
    assert_predicate committed, :applied?, committed.outcome.inspect
  end

  def sealed_request(run, key)
    invocation = ModelInvocation.find(node(run, key).selected_model_invocation_id)
    invocation.content_bodies.find_by!(role: "request").content_body_entries
      .map { |entry| entry.content_fragment.payload }.to_json
  end

  test "steer_now reads pending receipts immediately and preserves the original foreground join" do
    run, tokens = steer_fixture
    commit_claimed_tool(run, tokens, "r1t0", "short task complete")
    original_request = sealed_request(run, "ask")
    ordinary = loop_input!(run, acting_user: @human, text: "first correction")
    assert_predicate ordinary, :accepted?
    schedule!(run)
    assert_equal "queued", node(run, "r1").status
    assert_not run.tasks.exists?(node_key: "steer1")

    immediate = loop_input!(run, acting_user: @human, text: "inspect the running work now", delivery_mode: "steer_now")
    assert_predicate immediate, :accepted?, immediate.outcome.inspect
    schedule!(run)
    long = node(run, "r1t1")
    assert_equal "dispatched", long.status
    assert_not_nil long.claimed_at
    assert_nil long.completed_at
    assert_not long.detached?
    assert_equal "running", node(run, "steer1").status
    assert_equal "queued", node(run, "r1").status
    assert_equal "r1", run.reload.deliverable.node_key
    assert_equal "r1", run.mainline_tail.node_key
    assert_equal "r1", Runs::CurrentModel.for_loops([run]).fetch(run.id).node_key,
      "the newer inserted steer is read by the original continuation"
    assert_equal %w[steer1], node(run, "r1").input_from_node_keys
    assert_equal %w[r1t1], node(run, "r1").result_from_node_keys
    assert_not Input.exists?(id: [ordinary.value.id, immediate.value.id])
    request = sealed_request(run, "steer1")
    assert_equal 1, request.scan("short task complete").length
    assert_includes request, "still pending"
    assert_includes request, "r1t1 (dispatched)"
    assert_operator request.index("first correction"), :<, request.index("inspect the running work now")
    refute_includes request, Runs::RoundReplay::Pairing::UNANSWERED
    assert_equal original_request, sealed_request(run, "ask")

    run_step!(run, sse_success("I can inspect it while it runs."), key: "steer1")
    assert_equal "running", run.reload.status
    assert_equal "queued", node(run, "r1").status
    commit_claimed_tool(run, tokens, "r1t1", "long task complete")
    schedule!(run)
    assert_equal "running", node(run, "r1").status
    final_request = sealed_request(run, "r1")
    assert_equal 1, final_request.scan("short task complete").length
    assert_equal 1, final_request.scan("long task complete").length
    assert_operator final_request.index("I can inspect it while it runs."), :<, final_request.index("long task complete")
    assert_equal request, sealed_request(run, "steer1")
    assert_equal original_request, sealed_request(run, "ask")
    run_step!(run, sse_success("all complete"), key: "r1")
    assert_equal "completed", run.reload.status

    rounds = Runs::InputComposition.order_rounds(run.mainline_nodes.order(:id).to_a)
    assert_equal %w[ask steer1 r1], rounds.map(&:node_key)
    receipts = Runs::Steers::ToolReceipts.by_source(rounds)
    replay = Runs::RoundReplay.call(node(run, "ask"),
      fan_by_call_id: Runs::RoundReplay.fans_of(rounds).fetch(node(run, "ask").id),
      receipts: receipts.fetch(node(run, "ask").id))
    paired = replay.result_items.map(&:payload).to_json
    assert_includes paired, "still pending"
    refute_includes paired, "long task complete"
    material = Runs::InputComposition.material_by_round(rounds)
    assert_includes material.fetch(node(run, "r1").id).map(&:to_h).to_json, "long task complete"
    history = Conversations::Compaction::Serialize.loop_history(node(run, "r1"))
    assert_includes history.entries.join("\n"), "still pending"
    refute_includes history.entries.join("\n"), "Tool read_file (completed, result available): {\"path\":\"long\"}"
  end

  test "steer_now keeps a tool that completes during the model invocation behind that model" do
    run, tokens = steer_fixture
    commit_claimed_tool(run, tokens, "r1t0", "short done")
    accepted = loop_input!(run, acting_user: @human, text: "inspect now", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(run)
    pending_request = sealed_request(run, "steer1")
    commit_claimed_tool(run, tokens, "r1t1", "long result during steer")
    schedule!(run)
    assert_equal "queued", node(run, "r1").status
    assert_equal 1, node(run, "r1").remaining_dependencies
    assert_equal "running", node(run, "steer1").status
    run_step!(run, sse_success("steer response"), key: "steer1")
    assert_equal "running", node(run, "r1").status
    assert_equal pending_request, sealed_request(run, "steer1")
    request = sealed_request(run, "r1")
    assert_equal 1, request.scan("long result during steer").length
    assert_operator request.index("steer response"), :<, request.index("long result during steer")
  end

  test "successive steer_now rounds can launch tools while the original long tool stays claimed" do
    run, tokens = steer_fixture
    commit_claimed_tool(run, tokens, "r1t0", "short done")
    accepted = loop_input!(run, acting_user: @human, text: "first immediate", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(run)
    run_step!(run, sse_success("first acknowledgement"), key: "steer1")
    accepted = loop_input!(run, acting_user: @human, text: "second immediate", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(run)
    assert_equal "running", node(run, "steer2").status
    assert_equal %w[steer2], node(run, "r1").input_from_node_keys
    run_step!(run, sse_success("inspecting", tool_calls: calls("inspect")), key: "steer2")
    assert_equal "dispatched", node(run, "r2t0").status
    assert_equal "dispatched", node(run, "r1t1").status
    assert_not_nil node(run, "r1t1").claimed_at
    submit!(run, "r2t0", content: "inspection output")
    schedule!(run)
    run_step!(run, sse_success("inspection conclusion"), key: "r2")
    assert_equal "queued", node(run, "r1").status
    assert_equal %w[r2], node(run, "r1").input_from_node_keys
    commit_claimed_tool(run, tokens, "r1t1", "original long result")
    schedule!(run)
    request = sealed_request(run, "r1")
    %w[first\ immediate second\ immediate original\ long\ result inspection\ output].each do |text|
      assert_equal 1, request.scan(text).length, text
    end
    assert_operator request.index("inspection conclusion"), :<, request.index("original long result")
    run_step!(run, sse_success("joined all work"), key: "r1")
    assert_equal "completed", run.reload.status
  end

  test "steer_now waits through pause and does not weaken an explicit stop" do
    run, tokens = steer_fixture
    commit_claimed_tool(run, tokens, "r1t0", "short done")
    paused = Runs::Pause.call(Runs::Pause::Command.graceful(run: run, acting_user: @human))
    assert_predicate paused, :accepted?
    accepted = loop_input!(run, acting_user: @human, text: "inspect on resume", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(run)
    assert_not run.tasks.exists?(node_key: "steer1")
    assert Input.exists?(accepted.value.id)
    assert_equal "dispatched", node(run, "r1t1").status
    resumed = Runs::Resume.call(Runs::Resume::Command.new(run: run, acting_user: @human))
    assert_predicate resumed, :accepted?
    schedule!(run)
    assert_equal "running", node(run, "steer1").status
    stopped = Runs::Stop.call(Runs::Stop::Command.forced(run: run, acting_user: @human))
    assert_predicate stopped, :accepted?
    assert_equal "canceled", node(run, "r1t1").status
    assert_equal "canceled", node(run, "r1").status
    Runs::ConvergeTerminalSteps.call
    schedule!(run)
    assert_equal "canceled", node(run, "steer1").status
    assert_equal "canceled", run.reload.status
  end

  test "steer_now can discuss a parked approval without granting it" do
    run = seed(model("ask", "prompt" => "read it"), approval_mode: "ask")
    start!(run)
    run_step!(run, sse_success("calling", tool_calls: calls("approval")), key: "ask")
    assert_equal "needs_approval", node(run, "r1t0").status
    accepted = loop_input!(run, acting_user: @human, text: "explain before I approve", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(run)
    assert_equal "running", node(run, "steer1").status
    assert_equal "needs_approval", node(run, "r1t0").status
    assert_nil node(run, "r1t0").claimed_at
    assert_includes sealed_request(run, "steer1"), "needs_approval"
    run_step!(run, sse_success("approval explanation"), key: "steer1")
    assert_equal "queued", node(run, "r1").status
    assert_equal "needs_approval", node(run, "r1t0").status
  end

  test "steer_now remains bound while several mainline models are in flight" do
    run = seed(parallel(model("left"), model("right")), model("merge"))
    start!(run)
    accepted = loop_input!(run, acting_user: @human, text: "ambiguous immediate", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(run)
    assert_not run.tasks.exists?(node_key: "steer1")
    assert Input.exists?(accepted.value.id)
    refute_includes sealed_request(run, "left"), "ambiguous immediate"
    refute_includes sealed_request(run, "right"), "ambiguous immediate"
  end
end
