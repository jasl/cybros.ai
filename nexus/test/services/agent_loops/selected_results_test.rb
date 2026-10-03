require "test_helper"

class AgentLoops::SelectedResultsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "selected model output is ordered material and never the reader's history" do
    agent_loop = seed(parallel(
      model("first", "prompt" => "private producer history"),
      tool("second", "read_file"),
      model("reader", "results" => %w[second first])
    ), model("final"))
    finish(agent_loop, "first", "first selected answer")
    finish(agent_loop, "second", "second selected answer")

    result = compose(agent_loop, "reader")
    assert_predicate result, :composed?
    assert_nil result.history_source
    assert_equal 0, result.replayed_count
    text = result.elements.map(&:to_h).to_json
    assert_operator text.index("second selected answer"), :<, text.index("first selected answer")
    texts = result.elements.map { |element| element.parts.first.text }
    refute_includes texts, "private producer history", "the producer's brief is never replayed as history"
    assert_equal 1, text.scan("private producer history").length, "it rides once, as the envelope's <prompt> line"
  end

  # A NAMED RESULT SAYS WHERE IT CAME FROM: a tool's by its call, a model's by its brief — which is
  # how two results handed to one step are told apart. Only a read across a stage's boundary drops
  # the brief (the producer's context, which that boundary keeps).
  test "a selected tool result names its call and a selected model result carries its brief" do
    agent_loop = seed(parallel(
      model("first", "prompt" => "private producer brief"),
      tool("second", "read_file", "input" => { "path" => "b.rb" }),
      model("reader", "results" => %w[second first])
    ), model("final"))
    finish(agent_loop, "first", "first selected answer")
    finish(agent_loop, "second", "second selected answer")

    result = compose(agent_loop, "reader")
    assert_predicate result, :composed?
    texts = result.elements.map { |element| element.parts.first.text }
    assert_includes texts, "<task_result task=\"second\" status=\"completed\">\n" \
      "<call>read_file {\"path\":\"b.rb\"}</call>\nsecond selected answer\n</task_result>"
    assert_includes texts, "<task_result task=\"first\" status=\"completed\">\n<prompt>private producer brief</prompt>\n" \
      "first selected answer\n</task_result>"
  end

  test "compaction replaces history while preserving selected results" do
    agent_loop = seed(parallel(
      tool("summary", "read_file"), tool("selected", "read_file"),
      model("reader", "results" => ["selected"])
    ), model("final"))
    finish(agent_loop, "summary", "short history")
    finish(agent_loop, "selected", "required selected data")
    reader = node(agent_loop, "reader")
    AgentLoopNode.where(id: reader.id).update_all(compaction: { "summary_source" => "summary" })

    result = compose(agent_loop, "reader")
    assert_predicate result, :composed?
    text = result.elements.map(&:to_h).to_json
    assert_includes text, "short history"
    assert_includes text, "required selected data"
  end

  test "an explicit result also present as ordinary material is rendered once" do
    agent_loop = seed(tool("source", "read_file"), model("reader", "results" => ["source"]))
    finish(agent_loop, "source", "one selected answer")

    result = compose(agent_loop, "reader")
    assert_predicate result, :composed?
    assert_equal 1, result.elements.map(&:to_h).to_json.scan("one selected answer").length
  end

  # THE ROUND A STEP CONTINUES IS READ ONCE, AS HISTORY. A reducer on the loop's own path continues
  # the spine round before it: its request replays that round's brief and answer. Naming that round
  # beside the fan's fresh branches delivers the branches as result material, in declaration order,
  # and never the continued round as a second envelope of the answer its history already carries.
  test "a reducer naming the round it continues reads that round once, as history" do
    agent_loop = seed(model("a", "prompt" => "review A"),
      parallel(model("b", "prompt" => "review B"), model("c", "prompt" => "review C")),
      model("report", "prompt" => "reduce", "results" => %w[a b c]))
    start!(agent_loop)
    %w[a b c].each { |key| answer!(agent_loop, key, "#{key.upcase} REVIEW") }

    report = node(agent_loop, "report")
    assert_equal "running", report.status
    assert_equal [["user", "review A"], ["assistant", "Mock: A REVIEW"],
                  ["user", envelope("b", "<prompt>review B</prompt>", "Mock: B REVIEW")],
                  ["user", envelope("c", "<prompt>review C</prompt>", "Mock: C REVIEW")],
                  ["user", "reduce"]], texts_of(round_request_entries(report))
  end

  # The rule is the continued round's alone: a model that round's own replayed request carries
  # further back is not the round the step continues, so naming it still delivers its envelope.
  test "a model the continued round's history carries further back keeps its envelope" do
    agent_loop = seed(model("a", "prompt" => "angle A"), model("m", "prompt" => "approach M"),
      model("report", "results" => %w[a m]))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("A ANSWER"))
    run_loop_round!(agent_loop, sse_success("M ANSWER"))

    report = node(agent_loop, "report")
    assert_equal "running", report.status
    assert_equal [["user", "angle A"], ["assistant", "Mock: A ANSWER"], ["user", "approach M"],
                  ["assistant", "Mock: M ANSWER"], ["user", envelope("a", "<prompt>angle A</prompt>", "Mock: A ANSWER")],
                  ["user", "p"]],
      texts_of(round_request_entries(report))
  end

  test "a model refused before invocation retains selected data for its ordinary continuation" do
    agent_loop = seed(tool("source", "read_file"),
      model("unavailable", "results" => ["source"], "on_failure" => "absorb"), model("report"), model("final"))
    finish(agent_loop, "source", "selected data never sent to a provider")
    node(agent_loop, "unavailable").update_columns(status: "failed", error_key: "model_unavailable",
      completed_at: Time.current)

    result = compose(agent_loop, "report")
    assert_predicate result, :composed?
    text = result.elements.map(&:to_h).to_json
    assert_includes text, "selected data never sent to a provider"
    assert_includes text, "model_unavailable"
  end

  test "summarization carries an explicitly selected tool result as a pointer" do
    agent_loop = seed(tool("source", "read_file"), model("reader", "results" => ["source"]), model("final"))
    started = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    assert_predicate started, :accepted?
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    settled = AgentLoops::Parks::Settle.call(node: node(agent_loop, "source"), trusted: true,
      content: "opaque source bytes must be re-read", outcome: "completed")
    assert_predicate settled, :applied?, settled.outcome.inspect
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    reader = node(agent_loop, "reader")
    assert reader.selected_model_invocation_id
    assert_includes reader.invocation_body("request").entry_payloads.to_json, "opaque source bytes must be re-read"

    transcript = Conversations::Compaction::Serialize.loop_entries(node(agent_loop, "final")).join("\n")

    assert_includes transcript, "Tool read_file (completed, ok)"
    assert_includes transcript, "not carried; re-read it if needed"
    refute_includes transcript, "opaque source bytes must be re-read"
  end

  private

    def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

    def finish(agent_loop, key, output)
      row = node(agent_loop, key)
      assert_predicate ContentBodies::Replace.call(owner: row, role: "output",
        entries: [{ "text" => output }], seal: true), :accepted?
      # Only stored result composition is under test; no executor or model call.
      row.update_columns(status: "completed", completed_at: Time.current)
    end

    def compose(agent_loop, key)
      reader = node(agent_loop, key)
      AgentLoops::InputComposition.call(node: reader, input: reader.input_value)
    end

    def start!(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      schedule_loop!(agent_loop)
    end

    # One round of the real chain for the model at `key`, whichever of a fan's rounds runs.
    def answer!(agent_loop, key, text)
      invocation_id = node(agent_loop, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      apply_via(ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last, sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_loop)
    end

    def envelope(key, *lines, status: "completed")
      ["<task_result task=\"#{key}\" status=\"#{status}\">", *lines, "</task_result>"].join("\n")
    end

    def texts_of(entries) = entries.map { |entry| [entry["role"], entry.dig("parts", 0, "text")] }
end
