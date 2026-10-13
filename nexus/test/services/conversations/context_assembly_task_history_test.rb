require "test_helper"

class Conversations::ContextAssemblyTaskHistoryTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: workspaces(:shared),
      creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, READ_TOOL])
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
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "work in parallel")
    schedule_loop!(agent_run)
    apply_via(attempt_for(agent_run, "r1"), sse_success("delegating", tool_calls: [
      { id: "call_background", name: "delegate_task", arguments: { prompt: "background work", wait: false, lifetime: "turn" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    finish_round(agent_run, "r2t0-model-1", "background result")
    finish_round(agent_run, "r2", "foreground result")
    wake_request = round_request_entries(loop_node(agent_run, "w1"))
    finish_round(agent_run, "w1", "synthesized both")
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status

    _turn, next_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "continue")
    schedule_loop!(next_loop)
    next_request = round_request_entries(loop_node(next_loop, "r1"))

    assert_equal wake_request, next_request.take(wake_request.length),
      "the launch acknowledgement and later delivery keep the positions the model read"
  end

  test "steer_now history and prune keep the pending receipt and late result at their consumption positions" do
    declare_tools!(@agent, tools: [READ_TOOL])
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "run a long read")
    schedule_loop!(agent_run)
    apply_via(attempt_for(agent_run, "r1"), sse_success("starting read", tool_calls: [
      { id: "call_long", name: "read_file", arguments: { path: "long" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    schedule_loop!(agent_run)
    input = post_input!(@conversation, acting_user: @human, text: "inspect now", delivery_mode: "steer_now")
    assert_equal "steering", input.state
    schedule_loop!(agent_run)
    pending_request = round_request_entries(loop_node(agent_run, "steer1"))
    assert_includes pending_request.to_json, "still pending"
    finish_round(agent_run, "steer1", "immediate answer")
    settled = AgentRuns::Parks::Settle.call(node: loop_node(agent_run, "r2t0"), trusted: true,
      content: "late read secret value", outcome: "completed")
    assert_predicate settled, :applied?
    schedule_loop!(agent_run)
    final_request = round_request_entries(loop_node(agent_run, "r2"))
    assert_equal 1, final_request.to_json.scan("late read secret value").length

    pruned = loop_node(agent_run, "r2")
    original_compaction = pruned.compaction
    AgentRunTask.where(id: pruned.id).update_all(compaction: { "pruned_before" => "steer1" })
    composed = AgentRuns::InputComposition.call(node: pruned.reload, input: pruned.input_value)
    assert_predicate composed, :composed?, composed.refusal.inspect
    replayed = Nexus::InputEntries.for(composed.elements).to_json
    assert_includes replayed, "still pending"
    assert_equal 1, replayed.scan("late read secret value").length
    assert_operator replayed.index("immediate answer"), :<, replayed.index("late read secret value")
    assert_equal pending_request, round_request_entries(loop_node(agent_run, "steer1"))
    AgentRunTask.where(id: pruned.id).update_all(compaction: original_compaction)

    finish_round(agent_run, "r2", "joined answer")
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    _next_turn, next_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "continue")
    schedule_loop!(next_loop)
    next_request = round_request_entries(loop_node(next_loop, "r1"))
    assert_equal final_request, next_request.take(final_request.length)
    assert_equal 1, next_request.to_json.scan("late read secret value").length
    summary = Conversations::Compaction::Serialize.timeline_entries(@conversation).join("\n")
    assert_includes summary, "still pending"
    assert_operator summary.index("immediate answer"), :<, summary.index("(completed, ok)")
    refute_includes summary, "late read secret value"
  end

  test "an ask answer remains in later history even when the model does not repeat it" do
    turn, agent_run = answered_ask
    finish_round(agent_run, "r2", "recorded")
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_includes Conversations::Compaction::Serialize.timeline_entries(@conversation).join("\n"), "blue-cedar-42"

    _turn, next_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "recall my choice")
    schedule_loop!(next_loop)
    next_request = round_request_entries(loop_node(next_loop, "r1"))

    assert_includes next_request.to_json, "blue-cedar-42"
  end

  test "an unminted ask consumer does not add an answer to history" do
    _turn, agent_run = awaiting_ask
    assert_nil loop_node(agent_run, "r2").selected_model_invocation_id

    history = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation)

    refute history.segments.select { |segment| segment.role == "user" }
      .any? { |segment| segment.text.include?("<answer task=") }
  end

  test "prune and loop summarization retain an earlier ask answer" do
    _turn, agent_run = answered_ask
    apply_via(attempt_for(agent_run, "r2"), sse_success("recorded", tool_calls: [
      { id: "call_read", name: "read_file", arguments: { path: "notes.txt" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    schedule_loop!(agent_run)
    body = "stored data " * 300
    settled = AgentRuns::Parks::Settle.call(
      node: agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read"), trusted: true,
      content: body, outcome: "completed"
    )
    assert_predicate settled, :applied?, settled.outcome.inspect
    schedule_loop!(agent_run)
    consumed = round_request_entries(loop_node(agent_run, "r3"))
      .find { |entry| entry.dig("payload", "call_id") == "call_read" && entry["type"] == "tool_result_item" }
    assert_equal body, consumed.fetch("payload").fetch("output")
    apply_via(attempt_for(agent_run, "r3"), sse_success("read the stored data"))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    grow!(agent_run, model("after_read", "prompt" => "Continue from the stored data"))
    round = loop_node(agent_run, "after_read")
    assert_includes Conversations::Compaction::Serialize.loop_entries(round).join("\n"), "blue-cedar-42"

    repair = Conversations::Compaction::Arm.call(agent_run: agent_run, node: round,
      trigger: Conversations::Compaction::Trigger.wall(round,
        overshoot: Conversations::Compaction::Overshoot.bytes(1)))
    assert_predicate repair, :pruned?
    composed = AgentRuns::InputComposition.call(node: round.reload, input: round.input_value)

    assert_predicate composed, :composed?, composed.refusal.inspect
    entries = Nexus::InputEntries.for(composed.elements)
    assert_includes entries.to_json, "blue-cedar-42"
    results = entries.select { |entry| entry["type"] == "tool_result_item" }
      .to_h { |entry| entry.fetch("payload").values_at("call_id", "output") }
    assert_equal AgentRuns::RoundReplay::Pairing::CLEARED, results.fetch("call_read")
  end

  private

    def answered_ask
      turn, agent_run = awaiting_ask
      settled = AgentRuns::Parks::Settle.call(node: loop_node(agent_run, "r2t0-ask-1"),
        content: "blue-cedar-42", creator: @human)
      assert_predicate settled, :applied?, settled.outcome.inspect
      schedule_loop!(agent_run)
      assert_includes round_request_entries(loop_node(agent_run, "r2")).to_json, "blue-cedar-42"
      [turn, agent_run]
    end

    def awaiting_ask
      declare_tools!(@agent, tools: [Nexus::Tools::ASK, READ_TOOL])
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "save my choice")
      schedule_loop!(agent_run)
      apply_via(attempt_for(agent_run, "r1"), sse_success("asking", tool_calls: [
        { id: "call_choice", name: "ask", arguments: { prompt: "Which project label?" }.to_json },
      ]))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
        AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      end
      [turn, agent_run]
    end

    def task_turn(prompt, answer: nil, wait: true)
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: prompt)
      schedule_loop!(agent_run)
      apply_via(attempt_for(agent_run, "r1"), sse_success("delegating", tool_calls: [
        { id: "call_#{prompt}", name: "delegate_task", arguments: { prompt: prompt, wait: wait }.to_json },
      ]))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) do
        AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      end
      finish_round(agent_run, "r2t0-model-1", answer) if answer
      finish_round(agent_run, "r2", "#{prompt} delivered")
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      agent_run
    end

    def attempt_for(agent_run, key)
      invocation_id = loop_node(agent_run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def finish_round(agent_run, key, text)
      apply_via(attempt_for(agent_run, key), sse_success(text))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
    end

    def next_turn_results
      _turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "recall both")
      schedule_loop!(agent_run)
      round_request_entries(loop_node(agent_run, "r1")).filter_map do |entry|
        next unless entry["type"] == "tool_result_item"

        entry.fetch("payload").values_at("call_id", "output")
      end
    end

    def envelope(prompt, answer)
      "<task_result task=\"r2t0\" status=\"completed\">\n<prompt>#{prompt}</prompt>\nMock: #{answer}\n</task_result>"
    end
end
