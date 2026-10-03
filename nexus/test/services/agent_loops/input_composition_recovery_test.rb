require "test_helper"

class AgentLoops::InputCompositionRecoveryTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  # A ROUND REFUSED BEFORE MINTING has no sealed request to carry what it read, so the round that
  # continues it reads those inputs in its place — its spine's history and the results it named —
  # before its failure envelope.
  test "a round refused before minting hands its inputs to the continuation that replaces it" do
    agent_loop = seed(
      model("plan", "prompt" => "Investigate the patch"),
      tool("evidence", "read_file"),
      model("review", "prompt" => "Review the selected evidence", "model" => { "model" => "dev/no-such-model" },
        "on_failure" => "absorb", "results" => ["evidence"]),
      model("report", "prompt" => "Report the evidence and explain any failed review")
    )
    started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_predicate started, :accepted?
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("The patch changes the parser"))
    settled = AgentLoops::Parks::Settle.call(
      node: loop_node(agent_loop, "evidence"), trusted: true, content: "Selected parser evidence", outcome: "completed"
    )
    assert_predicate settled, :applied?
    schedule_loop!(agent_loop)

    review = loop_node(agent_loop, "review")
    report = loop_node(agent_loop, "report")
    assert_equal %w[failed unknown_model], review.values_at(:status, :error_key)
    assert_nil review.selected_model_invocation_id
    assert_equal [%w[plan], %w[evidence]], [review.input_from_node_keys, review.result_from_node_keys]
    assert_equal [%w[review], nil], [report.input_from_node_keys, report.result_from_node_keys]
    assert_equal "running", report.status
    assert_equal %w[plan review], AgentLoops::InputComposition.sources_for(report).map(&:node_key)

    texts = round_request_entries(report).filter_map { |entry| entry.dig("parts", 0, "text") }
    assert_equal "Investigate the patch", texts.first
    assert_includes texts, "Mock: The patch changes the parser"
    assert_equal 1, texts.count { |text| text.include?("Selected parser evidence") }, "the named result, once"
    assert(texts.any? { |text| text.start_with?('<task_result task="review" status="failed">') && text.include?("unknown_model") })
    assert_equal "Report the evidence and explain any failed review", texts.last
  end
end
