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
  def start!(run)
    Runs::Start.call(Runs::Start::Command.new(
      run: run, acting_user: @human
    ))
    Runs::ScheduleReady.call(run_id: run.id)
    run.reload
  end
  def node(run, key) = run.tasks.find_by!(node_key: key)
  def resolve!(node, **over)
    Runs::Parks::Settle.call(
      node: node, claim_token: node.resolution_token, content: "the answer", **over
    )
  end
  def declared(name)
    { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
  end
  def attempt_of(run, key)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == node(run, key).selected_model_invocation_id
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
    run = seed(model("round1", "prompt" => "go", "tools" => [declared("read_file")]),
      model("m2", "prompt" => "then"))
    start!(run)
    apply_via(attempt_of(run, "round1"), sse_success("calling", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(run)
    call = run.tasks.find_by!(tool_call_id: "call_read")
    assert_equal "dispatched", call.status

    assert_predicate Runs::Parks::Settle.call(node: call, trusted: true, **result), :applied?
    schedule_loop!(run)
    continuation = node(run, "r1")
    assert_equal "running", continuation.status, "the model reads the result on the next round"
    build(attempt_of(run, "r1"))
    item = round_request_entries(continuation).find { |payload| payload["type"] == "tool_result_item" }
    [call.reload, item.dig("payload", "output")]
  end
  # The frontier's own membership, without expiring anything.
  def frontier_ids
    Runs::Parks::TimeoutSweep.new.send(:frontier, DatabaseClock.now).map(&:id)
  end
  def executor_commit(run, key, executor, content:, outcome: nil)
    Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: key, executor: executor, claim_token: nil,
      content: content, structured_content: nil, result_type: nil, outcome: outcome,
      is_error: false, title: nil, metadata: nil
    ))
  end
  def ask_through_the_model!(run)
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
    round = node(run, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("asking", tool_calls: [
      { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
    ]))
    Runs::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [Runs::AskJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    run.tasks.where(type: Tasks::AwaitTask.sti_name).sole
  end
end
