require "test_helper"

class AgentLoops::ComposeFailureTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a composed model reads its predecessor's failure after the retry budget is exhausted" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION], "retry" => 1))
    started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_predicate started, :accepted?
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("composing", tool_calls: [
      { id: "compose_call", name: "compose", arguments: {
        script: <<~JS,
          const review = g.model({ prompt: "Review the patch", key: "review" });
          g.model({ prompt: "Summarize the review", key: "summary", results: [review] });
        JS
        wait: true,
      }.to_json },
    ]))
    AgentLoops::ComposeJob.perform_now(loop_node(agent_loop, "r1t0").id)
    schedule_loop!(agent_loop)

    review = loop_node(agent_loop, "r1t0-review")
    summary = loop_node(agent_loop, "r1t0-summary")
    assert_equal "absorb", review.on_failure
    assert_equal 1, review.retry_budget
    failure = json_response(400, { "error" => { "message" => "Review request could not run" } })
    run_loop_round!(agent_loop, failure)
    assert_equal "running", review.reload.status
    assert_equal 1, review.execution_generation
    assert_equal "queued", summary.reload.status

    run_loop_round!(agent_loop, failure)
    assert_equal %w[failed provider_http_error], review.reload.values_at(:status, :error_key)
    assert_equal "running", summary.reload.status
    texts = round_request_entries(summary).filter_map { |entry| entry.dig("parts", 0, "text") }.join("\n")
    assert_includes texts, '<task_result task="r1t0-review" status="failed">'
    assert_includes texts, "Review request could not run"
    assert_includes texts, "Summarize the review"
  end

  test "a composed model sees why its predecessor failed after producing output" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION, READ_TOOL]))
    started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_predicate started, :accepted?
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("composing", tool_calls: [
      { id: "compose_call", name: "compose", arguments: {
        script: <<~JS,
          const review = g.model({ prompt: "Review the patch", key: "review" });
          g.model({ prompt: "Summarize the review", key: "summary", results: [review] });
        JS
        wait: true,
      }.to_json },
    ]))
    AgentLoops::ComposeJob.perform_now(loop_node(agent_loop, "r1t0").id)
    schedule_loop!(agent_loop)

    # A fan wider than one continuation may wait on is the round the kernel cannot author.
    wide = (0..AgentLoops::Tasks::Compile::KERNEL_MAX_DEPENDENCIES_PER_TASK).map do |n|
      { id: "call_#{n}", name: "read_file", arguments: "{}" }
    end
    run_loop_round!(agent_loop, sse_success("I will read the patch before answering", tool_calls: wide))

    review = loop_node(agent_loop, "r1t0-review")
    summary = loop_node(agent_loop, "r1t0-summary")
    assert_predicate ModelInvocation.find(review.selected_model_invocation_id), :completed?
    assert_equal %w[failed round_expansion_refused], review.values_at(:status, :error_key)
    refused = review.error_detail
    assert_predicate refused, :present?, "the refusal names its reason"
    assert_includes review.output_body.effective_text, "I will read the patch before answering"
    assert_equal "running", summary.status
    texts = round_request_entries(summary).filter_map { |entry| entry.dig("parts", 0, "text") }.join("\n")
    assert_includes texts, '<task_result task="r1t0-review" status="failed">'
    assert_includes texts, "round_expansion_refused"
    assert_includes texts, refused
  end

  test "a composed model reads what it names through consecutive unavailable models" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION, READ_TOOL]))
    started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_predicate started, :accepted?
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("composing", tool_calls: [
      { id: "compose_call", name: "compose", arguments: {
        script: <<~JS,
          const prefix = g.model({ prompt: "Inspect the base patch", key: "prefix" });
          const patch = g.tool({ name: "read_file", input: { path: "patch.diff" }, key: "patch" });
          const review = g.model({ prompt: "Review the patch", key: "review", model: "dev/no-such-model" });
          const tests = g.model({ prompt: "Review the tests", key: "tests", model: "dev/also-unavailable" });
          g.model({ prompt: "Summarize the review", key: "summary", results: [prefix, patch, review, tests] });
        JS
        wait: true,
      }.to_json },
    ]))
    AgentLoops::ComposeJob.perform_now(loop_node(agent_loop, "r1t0").id)
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("The base patch changes the parser"))
    patch = loop_node(agent_loop, "r1t0-patch")
    assert_equal "dispatched", patch.status
    settled = AgentLoops::Parks::Settle.call(
      node: patch, trusted: true, outcome: "completed", content: "The patch adds a parser regression test"
    )
    assert_predicate settled, :applied?
    schedule_loop!(agent_loop)

    prefix = loop_node(agent_loop, "r1t0-prefix")
    review = loop_node(agent_loop, "r1t0-review")
    tests = loop_node(agent_loop, "r1t0-tests")
    summary = loop_node(agent_loop, "r1t0-summary")
    assert_equal "completed", prefix.status
    assert_equal %w[failed unknown_model], review.values_at(:status, :error_key)
    assert_equal %w[failed unknown_model], tests.values_at(:status, :error_key)
    assert_nil review.selected_model_invocation_id
    assert_nil tests.selected_model_invocation_id
    assert_equal "running", summary.status
    texts = round_request_entries(summary).filter_map { |entry| entry.dig("parts", 0, "text") }.join("\n")
    assert_includes texts, "The base patch changes the parser"
    assert_includes texts, "The patch adds a parser regression test"
    assert_includes texts, '<task_result task="r1t0-review" status="failed">'
    assert_includes texts, '<task_result task="r1t0-tests" status="failed">'
    assert_includes texts, "unknown_model"
  end

  test "an unavailable model preserves a preceding request's bound picture" do
    picture = accounts(:cybros).content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(png_bytes), filename: "patch.png", content_type: "image/png", identify: false
      )
    )
    agent_loop = seed(
      model("prefix", "prompt" => "Inspect the screenshot", "attachments" => [picture.public_id]),
      model("review", "prompt" => "Review the patch", "model" => { "model" => "dev/no-such-model" },
        "on_failure" => "absorb"),
      model("summary", "prompt" => "Summarize the review")
    )
    started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_predicate started, :accepted?
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("The screenshot shows the parser changes"))

    review = loop_node(agent_loop, "review")
    summary = loop_node(agent_loop, "summary")
    assert_equal %w[failed unknown_model], review.values_at(:status, :error_key)
    assert_nil review.selected_model_invocation_id
    assert_equal "running", summary.status
    request = summary.invocation_body("request")
    assert_equal [picture.public_id], request.upload_parts.map(&:public_id)
    assert_equal [picture.id], request.content_uploads.map(&:id)
    assert_includes round_request_entries(summary).to_json, "The screenshot shows the parser changes"
  end
end
