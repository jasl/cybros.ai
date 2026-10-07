require "test_helper"

class AgentRuns::InputCompositionRecoveryTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  # A ROUND REFUSED BEFORE MINTING has no sealed request to carry what it read, so the round that
  # continues it reads those inputs in its place — its mainline's history and the results it named —
  # before its failure envelope.
  test "a round refused before minting hands its inputs to the continuation that replaces it" do
    agent_run = seed(
      model("plan", "prompt" => "Investigate the patch"),
      tool("evidence", "read_file"),
      model("review", "prompt" => "Review the selected evidence", "model" => { "model" => "dev/no-such-model" },
        "on_failure" => "absorb", "results" => ["evidence"]),
      model("report", "prompt" => "Report the evidence and explain any failed review")
    )
    started = AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate started, :accepted?
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("The patch changes the parser"))
    settled = AgentRuns::Parks::Settle.call(
      node: loop_node(agent_run, "evidence"), trusted: true, content: "Selected parser evidence", outcome: "completed"
    )
    assert_predicate settled, :applied?
    schedule_loop!(agent_run)

    review = loop_node(agent_run, "review")
    report = loop_node(agent_run, "report")
    assert_equal %w[failed unknown_model], review.values_at(:status, :error_key)
    assert_nil review.selected_model_invocation_id
    assert_equal [%w[plan], %w[evidence]], [review.input_from_node_keys, review.result_from_node_keys]
    assert_equal [%w[review], nil], [report.input_from_node_keys, report.result_from_node_keys]
    assert_equal "running", report.status
    assert_equal %w[plan review], AgentRuns::InputComposition.sources_for(report).map(&:node_key)

    texts = round_request_entries(report).filter_map { |entry| entry.dig("parts", 0, "text") }
    assert_equal "Investigate the patch", texts.first
    assert_includes texts, "Mock: The patch changes the parser"
    assert_equal 1, texts.count { |text| text.include?("Selected parser evidence") }, "the named result, once"
    assert(texts.any? { |text| text.start_with?('<task_result task="review" status="failed">') && text.include?("unknown_model") })
    assert_equal "Report the evidence and explain any failed review", texts.last
  end
end
