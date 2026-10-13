module AwaitsTestHelper
  extend ActiveSupport::Concern

  include InvocationHarness
  include RunLaneTestHelper

  included do
    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      @workspace = workspaces(:shared)
      DevModelLane.ensure_enabled!(@account)
    end
  end

  def await(key, **over) = ask(key, **over)
  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run.reload
  end
  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)
  def resolve!(node, **over)
    AgentRuns::Parks::Settle.call(
      node: node, claim_token: node.resolution_token, content: "the answer", **over
    )
  end
  def declared(name)
    { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
  end
  def attempt_of(agent_run, key)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == node(agent_run, key).selected_model_invocation_id
    end
    raise "#{key} not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end
  # THE SEALED BYTES a tool result becomes: a round calls `read_file` once, the runner settles the
  # call with `result`, and the continuation's request is BUILT — the pairing's
  # `function_call_output` is what the model reads of that result, and this answers it beside the
  # settled call. Never `effective_text` alone: that would keep passing on the wrong bytes.
  def paired_output_after(**result)
    agent_run = seed(model("round1", "prompt" => "go", "tools" => [declared("read_file")]),
      model("m2", "prompt" => "then"))
    start!(agent_run)
    apply_via(attempt_of(agent_run, "round1"), sse_success("calling", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(agent_run)
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read")
    assert_equal "dispatched", call.status

    assert_predicate AgentRuns::Parks::Settle.call(node: call, trusted: true, **result), :applied?
    schedule_loop!(agent_run)
    continuation = node(agent_run, "r1")
    assert_equal "running", continuation.status, "the model reads the result on the next round"
    build(attempt_of(agent_run, "r1"))
    item = round_request_entries(continuation).find { |payload| payload["type"] == "tool_result_item" }
    [call.reload, item.dig("payload", "output")]
  end
  # The frontier's own membership, without expiring anything.
  def frontier_ids
    AgentRuns::Parks::TimeoutSweep.new.send(:frontier, DatabaseClock.now).map(&:id)
  end
  def executor_commit(agent_run, key, executor, content:, outcome: nil)
    Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: key, executor: executor, claim_token: nil,
      content: content, structured_content: nil, result_type: nil, outcome: outcome,
      is_error: false, title: nil, metadata: nil
    ))
  end
  def ask_through_the_model!(agent_run)
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    round = node(agent_run, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("asking", tool_calls: [
      { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole
  end
end
