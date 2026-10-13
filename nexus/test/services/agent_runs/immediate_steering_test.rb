require "test_helper"
require_relative "../../test_helpers/agent_runs_round_driver_test_helper"

class AgentRuns::ImmediateSteeringTest < ActiveJob::TestCase
  include AgentRunsRoundDriverTestHelper

  def steer_fixture
    agent_run = seed(model("ask", "prompt" => "Run both tasks and report."))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("short", "long")), key: "ask")
    tokens = %w[r1t0 r1t1].to_h do |key|
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: agent_run, task_key: key, executor: suite_runner
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.inspect
      [key, claimed.value.claim_token]
    end
    [agent_run, tokens]
  end

  def commit_claimed_tool(agent_run, tokens, key, text)
    committed = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: key, executor: suite_runner, claim_token: tokens.fetch(key),
      content: text, structured_content: nil, result_type: nil, outcome: "completed",
      is_error: false, title: nil, metadata: nil
    ))
    assert_predicate committed, :applied?, committed.outcome.inspect
  end

  def sealed_request(agent_run, key)
    invocation = ModelInvocation.find(node(agent_run, key).selected_model_invocation_id)
    invocation.content_bodies.find_by!(role: "request").content_body_entries
      .map { |entry| entry.content_fragment.payload }.to_json
  end

  test "steer_now reads pending receipts immediately and preserves the original foreground join" do
    agent_run, tokens = steer_fixture
    commit_claimed_tool(agent_run, tokens, "r1t0", "short task complete")
    original_request = sealed_request(agent_run, "ask")
    ordinary = loop_input!(agent_run, acting_user: @human, text: "first correction")
    assert_predicate ordinary, :accepted?
    schedule!(agent_run)
    assert_equal "queued", node(agent_run, "r1").status
    assert_not agent_run.agent_run_tasks.exists?(node_key: "steer1")

    immediate = loop_input!(agent_run, acting_user: @human, text: "inspect the running work now", delivery_mode: "steer_now")
    assert_predicate immediate, :accepted?, immediate.outcome.inspect
    schedule!(agent_run)
    long = node(agent_run, "r1t1")
    assert_equal "dispatched", long.status
    assert_not_nil long.claimed_at
    assert_nil long.completed_at
    assert_not long.detached?
    assert_equal "running", node(agent_run, "steer1").status
    assert_equal "queued", node(agent_run, "r1").status
    assert_equal "r1", agent_run.reload.deliverable.node_key
    assert_equal %w[steer1], node(agent_run, "r1").input_from_node_keys
    assert_equal %w[r1t1], node(agent_run, "r1").result_from_node_keys
    assert_not ConversationInput.exists?(id: [ordinary.value.id, immediate.value.id])
    request = sealed_request(agent_run, "steer1")
    assert_equal 1, request.scan("short task complete").length
    assert_includes request, "still pending"
    assert_includes request, "r1t1 (dispatched)"
    assert_operator request.index("first correction"), :<, request.index("inspect the running work now")
    refute_includes request, AgentRuns::RoundReplay::Pairing::UNANSWERED
    assert_equal original_request, sealed_request(agent_run, "ask")

    run_step!(agent_run, sse_success("I can inspect it while it runs."), key: "steer1")
    assert_equal "running", agent_run.reload.status
    assert_equal "queued", node(agent_run, "r1").status
    commit_claimed_tool(agent_run, tokens, "r1t1", "long task complete")
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "r1").status
    final_request = sealed_request(agent_run, "r1")
    assert_equal 1, final_request.scan("short task complete").length
    assert_equal 1, final_request.scan("long task complete").length
    assert_operator final_request.index("I can inspect it while it runs."), :<, final_request.index("long task complete")
    assert_equal request, sealed_request(agent_run, "steer1")
    assert_equal original_request, sealed_request(agent_run, "ask")
    run_step!(agent_run, sse_success("all complete"), key: "r1")
    assert_equal "completed", agent_run.reload.status

    rounds = AgentRuns::InputComposition.order_rounds(agent_run.mainline_nodes.order(:id).to_a)
    assert_equal %w[ask steer1 r1], rounds.map(&:node_key)
    receipts = AgentRuns::Steers::ToolReceipts.by_source(rounds)
    replay = AgentRuns::RoundReplay.call(node(agent_run, "ask"),
      fan_by_call_id: AgentRuns::RoundReplay.fans_of(rounds).fetch(node(agent_run, "ask").id),
      receipts: receipts.fetch(node(agent_run, "ask").id))
    paired = replay.result_items.map(&:payload).to_json
    assert_includes paired, "still pending"
    refute_includes paired, "long task complete"
    material = AgentRuns::InputComposition.material_by_round(rounds)
    assert_includes material.fetch(node(agent_run, "r1").id).map(&:to_h).to_json, "long task complete"
    history = Conversations::Compaction::Serialize.loop_history(node(agent_run, "r1"))
    assert_includes history.entries.join("\n"), "still pending"
    refute_includes history.entries.join("\n"), "Tool read_file (completed, result available): {\"path\":\"long\"}"
  end

  test "steer_now keeps a tool that completes during the model invocation behind that model" do
    agent_run, tokens = steer_fixture
    commit_claimed_tool(agent_run, tokens, "r1t0", "short done")
    accepted = loop_input!(agent_run, acting_user: @human, text: "inspect now", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(agent_run)
    pending_request = sealed_request(agent_run, "steer1")
    commit_claimed_tool(agent_run, tokens, "r1t1", "long result during steer")
    schedule!(agent_run)
    assert_equal "queued", node(agent_run, "r1").status
    assert_equal 1, node(agent_run, "r1").remaining_dependencies
    assert_equal "running", node(agent_run, "steer1").status
    run_step!(agent_run, sse_success("steer response"), key: "steer1")
    assert_equal "running", node(agent_run, "r1").status
    assert_equal pending_request, sealed_request(agent_run, "steer1")
    request = sealed_request(agent_run, "r1")
    assert_equal 1, request.scan("long result during steer").length
    assert_operator request.index("steer response"), :<, request.index("long result during steer")
  end

  test "successive steer_now rounds can launch tools while the original long tool stays claimed" do
    agent_run, tokens = steer_fixture
    commit_claimed_tool(agent_run, tokens, "r1t0", "short done")
    accepted = loop_input!(agent_run, acting_user: @human, text: "first immediate", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(agent_run)
    run_step!(agent_run, sse_success("first acknowledgement"), key: "steer1")
    accepted = loop_input!(agent_run, acting_user: @human, text: "second immediate", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "steer2").status
    assert_equal %w[steer2], node(agent_run, "r1").input_from_node_keys
    run_step!(agent_run, sse_success("inspecting", tool_calls: calls("inspect")), key: "steer2")
    assert_equal "dispatched", node(agent_run, "r2t0").status
    assert_equal "dispatched", node(agent_run, "r1t1").status
    assert_not_nil node(agent_run, "r1t1").claimed_at
    submit!(agent_run, "r2t0", content: "inspection output")
    schedule!(agent_run)
    run_step!(agent_run, sse_success("inspection conclusion"), key: "r2")
    assert_equal "queued", node(agent_run, "r1").status
    assert_equal %w[r2], node(agent_run, "r1").input_from_node_keys
    commit_claimed_tool(agent_run, tokens, "r1t1", "original long result")
    schedule!(agent_run)
    request = sealed_request(agent_run, "r1")
    %w[first\ immediate second\ immediate original\ long\ result inspection\ output].each do |text|
      assert_equal 1, request.scan(text).length, text
    end
    assert_operator request.index("inspection conclusion"), :<, request.index("original long result")
    run_step!(agent_run, sse_success("joined all work"), key: "r1")
    assert_equal "completed", agent_run.reload.status
  end

  test "steer_now waits through pause and does not weaken an explicit stop" do
    agent_run, tokens = steer_fixture
    commit_claimed_tool(agent_run, tokens, "r1t0", "short done")
    paused = AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(agent_run: agent_run, acting_user: @human))
    assert_predicate paused, :accepted?
    accepted = loop_input!(agent_run, acting_user: @human, text: "inspect on resume", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(agent_run)
    assert_not agent_run.agent_run_tasks.exists?(node_key: "steer1")
    assert ConversationInput.exists?(accepted.value.id)
    assert_equal "dispatched", node(agent_run, "r1t1").status
    resumed = AgentRuns::Resume.call(AgentRuns::Resume::Command.new(agent_run: agent_run, acting_user: @human))
    assert_predicate resumed, :accepted?
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "steer1").status
    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: agent_run, acting_user: @human))
    assert_predicate stopped, :accepted?
    assert_equal "canceled", node(agent_run, "r1t1").status
    assert_equal "canceled", node(agent_run, "r1").status
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
    assert_equal "canceled", node(agent_run, "steer1").status
    assert_equal "canceled", agent_run.reload.status
  end

  test "steer_now can discuss a parked approval without granting it" do
    agent_run = seed(model("ask", "prompt" => "read it"), approval_mode: "ask")
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("approval")), key: "ask")
    assert_equal "needs_approval", node(agent_run, "r1t0").status
    accepted = loop_input!(agent_run, acting_user: @human, text: "explain before I approve", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "steer1").status
    assert_equal "needs_approval", node(agent_run, "r1t0").status
    assert_nil node(agent_run, "r1t0").claimed_at
    assert_includes sealed_request(agent_run, "steer1"), "needs_approval"
    run_step!(agent_run, sse_success("approval explanation"), key: "steer1")
    assert_equal "queued", node(agent_run, "r1").status
    assert_equal "needs_approval", node(agent_run, "r1t0").status
  end

  test "steer_now remains bound while several mainline models are in flight" do
    agent_run = seed(parallel(model("left"), model("right")), model("merge"))
    start!(agent_run)
    accepted = loop_input!(agent_run, acting_user: @human, text: "ambiguous immediate", delivery_mode: "steer_now")
    assert_predicate accepted, :accepted?
    schedule!(agent_run)
    assert_not agent_run.agent_run_tasks.exists?(node_key: "steer1")
    assert ConversationInput.exists?(accepted.value.id)
    refute_includes sealed_request(agent_run, "left"), "ambiguous immediate"
    refute_includes sealed_request(agent_run, "right"), "ambiguous immediate"
  end
end
