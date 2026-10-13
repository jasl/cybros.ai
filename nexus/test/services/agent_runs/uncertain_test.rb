require "test_helper"

# `uncertain` THROUGH THE REAL CHAIN: the sweep writes it on a claimed non-replayable call that
# expired with no result; then it is adjudicable exactly as `failed` is — a person's retry re-queues
# it under a new generation (because the PERSON decided the effect did not happen; the kernel never
# decides that), abandon resolves it in place — and on a model's fan an absorb resolves in the write
# and the continuation reads the flat-call sentence. Beside execution_test, which is at its size.
class AgentRuns::UncertainTest < ActiveJob::TestCase
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

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def claim!(agent_run, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result
  end

  # A claimed `bash` park the sweep finds overdue: the row nobody answered.
  def expire_claimed!(agent_run, key)
    claim!(agent_run, key)
    AgentRunTask.where(id: node(agent_run, key).id).update_all(await_started_at: 2.hours.ago)
    assert_equal 1, AgentRuns::Parks::TimeoutSweep.call[:expired]
    row = node(agent_run, key)
    assert_equal %w[uncertain tool_uncertain], row.values_at(:status, :error_key)
    assert_equal AgentRuns::Parks::Settle::UNCERTAIN_DETAIL, row.error_detail
    row
  end

  def step_attempt(agent_run, key)
    invocation_id = node(agent_run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def run!(agent_run, key, behaviour)
    apply_via(step_attempt(agent_run, key), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  # The denial sentences are keyed by `error_key`, layered above the status sentence: every
  # reference says WHO refused.
  test "the pairing reads the approval sentences by error_key and the status sentence otherwise" do
    pairing = AgentRuns::RoundReplay::Pairing
    row = ->(status, error_key, detail = nil) {
      AgentRunTasks::ToolTask.new(status: status, error_key: error_key, error_detail: detail)
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

  def paired_results(agent_run, key)
    ModelInvocation.find(node(agent_run, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
      .select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def attention_item(agent_run)
    agent_run.conversation_event_items.where(item_type: "attention_required").order(:sequence).last
  end

  test "an uncertain halt holds the loop, and retry re-queues it under a new generation with a clean claim" do
    agent_run = seed(tool("job", "bash", "on_failure" => "halt"))
    start!(agent_run)
    job = expire_claimed!(agent_run, "job")
    assert_nil job.failure_resolution, "nobody adjudicated it"
    assert_equal :pending, AgentRuns::Graph.settlement_of(job)

    agent_run.reload
    assert_equal %w[needs_attention halt_failure], [agent_run.status, agent_run.attention_reason]
    assert_equal ["job"], attention_item(agent_run).payload.fetch("blocked_task_keys"),
      "the narration names the row a person must look at"

    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "job", acting_user: @human
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
    agent_run.reload
    assert_equal "running", agent_run.status
    assert_nil agent_run.attention_reason

    schedule!(agent_run)
    job.reload
    assert_equal "dispatched", job.status, "the next start re-addresses and re-freezes the profile"
    assert_equal suite_runner.id, job.addressed_executor_id
    assert_equal "write", job.effect_profile.fetch("kind")
  end

  test "abandon resolves an uncertain call in place and releases what waited on it" do
    agent_run = seed(tool("job", "bash", "on_failure" => "halt"), model("after", "prompt" => "sum up"))
    start!(agent_run)
    job = expire_claimed!(agent_run, "job")
    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "queued", node(agent_run, "after").status

    result = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
      agent_run: agent_run, task_key: "job", acting_user: @human
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    job.reload
    assert_equal %w[uncertain abandoned], [job.status, job.failure_resolution], "resolved where it stands"
    assert_equal :resolved, AgentRuns::Graph.settlement_of(job)
    assert_equal 0, node(agent_run, "after").remaining_dependencies, "the dependent was released"
    assert_equal "running", agent_run.reload.status

    schedule!(agent_run)
    assert_equal "running", node(agent_run, "after").status
  end

  # The flat-call twin of the envelope: a model's fan call is `absorb`, so the sweep's write
  # resolves it, the continuation round is released, and its paired result carries the reason a
  # model can act on.
  test "an uncertain fan call absorbs, and the continuation reads the flat-call sentence" do
    agent_run = seed(model("round1", "prompt" => "run it", "tools" => [BASH_TOOL]))
    start!(agent_run)
    run!(agent_run, "round1", sse_success("running", tool_calls: [
      { id: "call_round1_0", name: "bash", arguments: { command: "x" }.to_json },
    ]))
    assert_equal %w[dispatched absorb], node(agent_run, "r1t0").values_at(:status, :on_failure)

    call = expire_claimed!(agent_run, "r1t0")
    assert_nil call.failure_resolution, "absorb resolves by policy, never by a stamp"
    assert_equal :resolved, AgentRuns::Graph.settlement_of(call)
    assert_equal "running", agent_run.reload.status, "an absorbed expiry holds nothing"
    assert_nil agent_run.attention_reason

    schedule!(agent_run)
    assert_equal "running", node(agent_run, "r1").status, "the continuation was released"
    run!(agent_run, "r1", sse_success("noted"))
    pairing = AgentRuns::RoundReplay::Pairing
    expected = "#{pairing::ERROR_OPEN}#{pairing::REASONS.fetch("uncertain")} (tool_uncertain) " \
      "#{AgentRuns::Parks::Settle::UNCERTAIN_DETAIL}#{pairing::ERROR_CLOSE}"
    assert_equal expected, paired_results(agent_run, "r1").fetch("call_round1_0")
    assert_equal "completed", agent_run.reload.status
  end
end
