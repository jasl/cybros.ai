require "test_helper"

class Conversations::ContextAssemblyTaskHistoryTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: workspaces(:shared),
      creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, READ_TOOL])
  end

  test "reused task keys in different turns retain each branch's own result" do
    first = task_turn("first", answer: "first result")
    second = task_turn("second", answer: "second result")
    assert_equal "r2t0", loop_node(first, "r2t0").node_key
    assert_equal "r2t0", loop_node(second, "r2t0").node_key

    assert_equal [
      ["call_first", envelope("first", "first result")],
      ["call_second", envelope("second", "second result")],
    ], next_turn_results
  end

  test "an unfinished background task cannot erase an earlier turn's same-key result" do
    task_turn("first", answer: "first result")
    background = task_turn("background", wait: false)
    assert_equal "running", loop_node(background, "r2t0-model-1").status
    receipt = loop_node(background, "r2t0").content_bodies.find_by!(role: "output").effective_text

    assert_equal [
      ["call_first", envelope("first", "first result")],
      ["call_background", receipt],
    ], next_turn_results
  end

  test "a background result consumed in the same turn preserves the wake request in later history" do
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "work in parallel")
    schedule_loop!(agent_loop)
    apply_via(attempt_for(agent_loop, "r1"), sse_success("delegating", tool_calls: [
      { id: "call_background", name: "task", arguments: { prompt: "background work", wait: false, lifetime: "turn" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    finish_round(agent_loop, "r2t0-model-1", "background result")
    finish_round(agent_loop, "r2", "foreground result")
    wake_request = round_request_entries(loop_node(agent_loop, "w1"))
    finish_round(agent_loop, "w1", "synthesized both")
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status

    _turn, next_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "continue")
    schedule_loop!(next_loop)
    next_request = round_request_entries(loop_node(next_loop, "r1"))

    assert_equal wake_request, next_request.take(wake_request.length),
      "the launch acknowledgement and later delivery keep the positions the model read"
  end

  test "an ask answer remains in later history even when the model does not repeat it" do
    turn, agent_loop = answered_ask
    finish_round(agent_loop, "r2", "recorded")
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_includes Conversations::Compaction::Serialize.timeline_entries(@conversation).join("\n"), "blue-cedar-42"

    _turn, next_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "recall my choice")
    schedule_loop!(next_loop)
    next_request = round_request_entries(loop_node(next_loop, "r1"))

    assert_includes next_request.to_json, "blue-cedar-42"
  end

  test "an unminted ask consumer does not add an answer to history" do
    _turn, agent_loop = awaiting_ask
    assert_nil loop_node(agent_loop, "r2").selected_model_invocation_id

    history = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation)

    refute history.segments.select { |segment| segment.role == "user" }
      .any? { |segment| segment.text.include?("<answer task=") }
  end

  test "prune and loop summarization retain an earlier ask answer" do
    _turn, agent_loop = answered_ask
    apply_via(attempt_for(agent_loop, "r2"), sse_success("recorded", tool_calls: [
      { id: "call_read", name: "read_file", arguments: { path: "notes.txt" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(agent_loop)
    body = "stored data " * 300
    settled = AgentLoops::Parks::Settle.call(
      node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_read"), trusted: true,
      content: body, outcome: "completed"
    )
    assert_predicate settled, :applied?, settled.outcome.inspect
    schedule_loop!(agent_loop)
    consumed = round_request_entries(loop_node(agent_loop, "r3"))
      .find { |entry| entry.dig("payload", "call_id") == "call_read" && entry["type"] == "tool_result_item" }
    assert_equal body, consumed.fetch("payload").fetch("output")
    apply_via(attempt_for(agent_loop, "r3"), sse_success("read the stored data"))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    grow!(agent_loop, model("after_read", "prompt" => "Continue from the stored data"))
    round = loop_node(agent_loop, "after_read")
    assert_includes Conversations::Compaction::Serialize.loop_entries(round).join("\n"), "blue-cedar-42"

    repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: round,
      trigger: Conversations::Compaction::Trigger.wall(round,
        overshoot: Conversations::Compaction::Overshoot.bytes(1)))
    assert_predicate repair, :pruned?
    composed = AgentLoops::InputComposition.call(node: round.reload, input: round.input_value)

    assert_predicate composed, :composed?, composed.refusal.inspect
    entries = Nexus::InputEntries.for(composed.elements)
    assert_includes entries.to_json, "blue-cedar-42"
    results = entries.select { |entry| entry["type"] == "tool_result_item" }
      .to_h { |entry| entry.fetch("payload").values_at("call_id", "output") }
    assert_equal AgentLoops::RoundReplay::Pairing::CLEARED, results.fetch("call_read")
  end

  private

    def answered_ask
      turn, agent_loop = awaiting_ask
      settled = AgentLoops::Parks::Settle.call(node: loop_node(agent_loop, "r2t0-ask-1"),
        content: "blue-cedar-42", creator: @human)
      assert_predicate settled, :applied?, settled.outcome.inspect
      schedule_loop!(agent_loop)
      assert_includes round_request_entries(loop_node(agent_loop, "r2")).to_json, "blue-cedar-42"
      [turn, agent_loop]
    end

    def awaiting_ask
      declare_tools!(@agent, tools: [Nexus::Tools::ASK, READ_TOOL])
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "save my choice")
      schedule_loop!(agent_loop)
      apply_via(attempt_for(agent_loop, "r1"), sse_success("asking", tool_calls: [
        { id: "call_choice", name: "ask", arguments: { prompt: "Which project label?" }.to_json },
      ]))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end
      [turn, agent_loop]
    end

    def task_turn(prompt, answer: nil, wait: true)
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: prompt)
      schedule_loop!(agent_loop)
      apply_via(attempt_for(agent_loop, "r1"), sse_success("delegating", tool_calls: [
        { id: "call_#{prompt}", name: "task", arguments: { prompt: prompt, wait: wait }.to_json },
      ]))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end
      finish_round(agent_loop, "r2t0-model-1", answer) if answer
      finish_round(agent_loop, "r2", "#{prompt} delivered")
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      agent_loop
    end

    def attempt_for(agent_loop, key)
      invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def finish_round(agent_loop, key, text)
      apply_via(attempt_for(agent_loop, key), sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def next_turn_results
      _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "recall both")
      schedule_loop!(agent_loop)
      round_request_entries(loop_node(agent_loop, "r1")).filter_map do |entry|
        next unless entry["type"] == "tool_result_item"

        entry.fetch("payload").values_at("call_id", "output")
      end
    end

    def envelope(prompt, answer)
      "<task_result task=\"r2t0\" status=\"completed\">\n<prompt>#{prompt}</prompt>\nMock: #{answer}\n</task_result>"
    end
end
