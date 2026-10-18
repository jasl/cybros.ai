require "test_helper"

# `uncertain` THROUGH THE REAL CHAIN: the sweep writes it on a claimed non-replayable call that
# expired with no result; then it is adjudicable exactly as `failed` is — a person's retry re-queues
# it under a new generation (because the PERSON decided the effect did not happen; the kernel never
# decides that), abandon resolves it in place — and on a model's fan an absorb resolves in the write
# and the continuation reads the flat-call sentence. Beside execution_test, which is at its size.
class Runs::UncertainTest < ActiveJob::TestCase
  include InvocationHarness

  BASH_TOOL = {
    "type" => "function",
    "function" => { "name" => "bash", "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def start!(run)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    clear_enqueued_jobs
    schedule!(run)
  end

  def schedule!(run)
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)

  def claim!(run, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result
  end

  # A claimed `bash` park the sweep finds overdue: the row nobody answered.
  def expire_claimed!(run, key)
    claim!(run, key)
    Task.where(id: node(run, key).id).update_all(await_started_at: 2.hours.ago)
    assert_equal 1, Runs::Parks::TimeoutSweep.call[:expired]
    row = node(run, key)
    assert_equal %w[uncertain tool_uncertain], row.values_at(:status, :error_key)
    assert_equal Runs::Parks::Settle::UNCERTAIN_DETAIL, row.error_detail
    row
  end

  def step_attempt(run, key)
    invocation_id = node(run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def run!(run, key, behaviour)
    apply_via(step_attempt(run, key), behaviour)
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
  end

  # The denial sentences are keyed by `error_key`, layered above the status sentence: every
  # reference says WHO refused.
  test "the pairing reads the approval sentences by error_key and the status sentence otherwise" do
    pairing = Runs::RoundReplay::Pairing
    row = ->(status, error_key, detail = nil) {
      Tasks::ToolTask.new(status: status, error_key: error_key, error_detail: detail)
    }
    assert_equal "#{pairing::ERROR_OPEN}This tool call was declined by the approver; do not run it again unchanged. "       "(approval_denied) use ls instead#{pairing::ERROR_CLOSE}",
      pairing.output_for(row.("failed", "approval_denied", "use ls instead"))
    assert_equal "#{pairing::ERROR_OPEN}Nobody approved this tool call before it expired. (approval_expired)#{pairing::ERROR_CLOSE}",
      pairing.output_for(row.("timed_out", "approval_expired"))
    assert_equal "#{pairing::ERROR_OPEN}#{pairing::REASONS.fetch("failed")} (tool_not_served)#{pairing::ERROR_CLOSE}",
      pairing.output_for(row.("failed", "tool_not_served"))
    assert_equal "#{pairing::ERROR_OPEN}#{pairing::REASONS.fetch("timed_out")} (tool_timeout)#{pairing::ERROR_CLOSE}",
      pairing.output_for(row.("timed_out", "tool_timeout"))
  end

  def paired_results(run, key)
    ModelInvocation.find(node(run, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
      .select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def attention_item(run)
    run.event_items.where(item_type: "attention_required").order(:sequence).last
  end

  test "an uncertain halt holds the loop, and retry re-queues it under a new generation with a clean claim" do
    run = seed(tool("job", "bash", "on_failure" => "halt"))
    start!(run)
    job = expire_claimed!(run, "job")
    assert_nil job.failure_resolution, "nobody adjudicated it"
    assert_equal :pending, Runs::Graph.settlement_of(job)

    run.reload
    assert_equal %w[needs_attention halt_failure], [run.status, run.attention_reason]
    assert_equal ["job"], attention_item(run).payload.fetch("blocked_task_keys"),
      "the narration names the row a person must look at"

    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "job", acting_user: @human
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    job.reload
    assert_equal "queued", job.status
    assert_equal 1, job.execution_generation
    assert_nil job.error_key
    assert_nil job.error_detail
    %i[claim_token claimed_at claimed_by_executor_id claimed_by_executor_public_id
       addressed_executor_id addressed_role effect_profile].each do |column|
      assert_nil job.public_send(column), "#{column} goes with the dead generation"
    end
    run.reload
    assert_equal "running", run.status
    assert_nil run.attention_reason

    schedule!(run)
    job.reload
    assert_equal "dispatched", job.status, "the next start re-addresses and re-freezes the profile"
    assert_equal suite_runner.id, job.addressed_executor_id
    assert_equal "write", job.effect_profile.fetch("kind")
  end

  test "abandon resolves an uncertain call in place and releases what waited on it" do
    run = seed(tool("job", "bash", "on_failure" => "halt"), model("after", "prompt" => "sum up"))
    start!(run)
    job = expire_claimed!(run, "job")
    assert_equal "needs_attention", run.reload.status
    assert_equal "queued", node(run, "after").status

    result = Runs::Tasks::Abandon.call(Runs::Tasks::Abandon::Command.new(
      run: run, task_key: "job", acting_user: @human
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    job.reload
    assert_equal %w[uncertain abandoned], [job.status, job.failure_resolution], "resolved where it stands"
    assert_equal :resolved, Runs::Graph.settlement_of(job)
    assert_equal 0, node(run, "after").remaining_dependencies, "the dependent was released"
    assert_equal "running", run.reload.status

    schedule!(run)
    assert_equal "running", node(run, "after").status
  end

  # The flat-call twin of the envelope: a model's fan call is `absorb`, so the sweep's write
  # resolves it, the continuation round is released, and its paired result carries the reason a
  # model can act on.
  test "an uncertain fan call absorbs, and the continuation reads the flat-call sentence" do
    run = seed(model("round1", "prompt" => "run it", "tools" => [BASH_TOOL]))
    start!(run)
    run!(run, "round1", sse_success("running", tool_calls: [
      { id: "call_round1_0", name: "bash", arguments: { command: "x" }.to_json },
    ]))
    assert_equal %w[dispatched absorb], node(run, "r1t0").values_at(:status, :on_failure)

    call = expire_claimed!(run, "r1t0")
    assert_nil call.failure_resolution, "absorb resolves by policy, never by a stamp"
    assert_equal :resolved, Runs::Graph.settlement_of(call)
    assert_equal "running", run.reload.status, "an absorbed expiry holds nothing"
    assert_nil run.attention_reason

    schedule!(run)
    assert_equal "running", node(run, "r1").status, "the continuation was released"
    run!(run, "r1", sse_success("noted"))
    pairing = Runs::RoundReplay::Pairing
    expected = "#{pairing::ERROR_OPEN}#{pairing::REASONS.fetch("uncertain")} (tool_uncertain) " \
      "#{Runs::Parks::Settle::UNCERTAIN_DETAIL}#{pairing::ERROR_CLOSE}"
    assert_equal expected, paired_results(run, "r1").fetch("call_round1_0")
    assert_equal "completed", run.reload.status
  end
end
