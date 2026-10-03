require "test_helper"

# `uncertain` THROUGH THE REAL CHAIN: the sweep writes it on a claimed non-replayable call that
# expired with no result; then it is adjudicable exactly as `failed` is — a person's retry re-queues
# it under a new generation (because the PERSON decided the effect did not happen; the kernel never
# decides that), abandon resolves it in place — and on a model's fan an absorb resolves in the write
# and the continuation reads the flat-call sentence. Beside execution_test, which is at its size.
class AgentLoops::UncertainTest < ActiveJob::TestCase
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

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  def schedule!(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def claim!(agent_loop, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result
  end

  # A claimed `bash` park the sweep finds overdue: the row nobody answered.
  def expire_claimed!(agent_loop, key)
    claim!(agent_loop, key)
    AgentLoopNode.where(id: node(agent_loop, key).id).update_all(await_started_at: 2.hours.ago)
    assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:expired]
    row = node(agent_loop, key)
    assert_equal %w[uncertain tool_uncertain], row.values_at(:status, :error_key)
    assert_equal AgentLoops::Parks::Settle::UNCERTAIN_DETAIL, row.error_detail
    row
  end

  def step_attempt(agent_loop, key)
    invocation_id = node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def run!(agent_loop, key, behaviour)
    apply_via(step_attempt(agent_loop, key), behaviour)
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  # The denial sentences are keyed by `error_key`, layered above the status sentence: every
  # reference says WHO refused.
  test "the pairing reads the approval sentences by error_key and the status sentence otherwise" do
    pairing = AgentLoops::RoundReplay::Pairing
    row = ->(status, error_key, detail = nil) {
      AgentLoopNodes::ToolTask.new(status: status, error_key: error_key, error_detail: detail)
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

  def paired_results(agent_loop, key)
    ModelInvocation.find(node(agent_loop, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
      .select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def attention_item(agent_loop)
    agent_loop.conversation_event_items.where(item_type: "attention_required").order(:sequence).last
  end

  test "an uncertain halt holds the loop, and retry re-queues it under a new generation with a clean claim" do
    agent_loop = seed(tool("job", "bash", "on_failure" => "halt"))
    start!(agent_loop)
    job = expire_claimed!(agent_loop, "job")
    assert_nil job.failure_resolution, "nobody adjudicated it"
    assert_equal :pending, AgentLoops::Graph.settlement_of(job)

    agent_loop.reload
    assert_equal %w[needs_attention halt_failure], [agent_loop.status, agent_loop.attention_reason]
    assert_equal ["job"], attention_item(agent_loop).payload.fetch("blocked_task_keys"),
      "the narration names the row a person must look at"

    result = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "job", acting_user: @human
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
    agent_loop.reload
    assert_equal "running", agent_loop.status
    assert_nil agent_loop.attention_reason

    schedule!(agent_loop)
    job.reload
    assert_equal "dispatched", job.status, "the next start re-addresses and re-freezes the profile"
    assert_equal suite_runner.id, job.addressed_executor_id
    assert_equal "write", job.effect_profile.fetch("kind")
  end

  test "abandon resolves an uncertain call in place and releases what waited on it" do
    agent_loop = seed(tool("job", "bash", "on_failure" => "halt"), model("after", "prompt" => "sum up"))
    start!(agent_loop)
    job = expire_claimed!(agent_loop, "job")
    assert_equal "needs_attention", agent_loop.reload.status
    assert_equal "queued", node(agent_loop, "after").status

    result = AgentLoops::Tasks::Abandon.call(AgentLoops::Tasks::Abandon::Command.new(
      agent_loop: agent_loop, task_key: "job", acting_user: @human
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    job.reload
    assert_equal %w[uncertain abandoned], [job.status, job.failure_resolution], "resolved where it stands"
    assert_equal :resolved, AgentLoops::Graph.settlement_of(job)
    assert_equal 0, node(agent_loop, "after").remaining_dependencies, "the dependent was released"
    assert_equal "running", agent_loop.reload.status

    schedule!(agent_loop)
    assert_equal "running", node(agent_loop, "after").status
  end

  # The flat-call twin of the envelope: a model's fan call is `absorb`, so the sweep's write
  # resolves it, the continuation round is released, and its paired result carries the reason a
  # model can act on.
  test "an uncertain fan call absorbs, and the continuation reads the flat-call sentence" do
    agent_loop = seed(model("round1", "prompt" => "run it", "tools" => [BASH_TOOL]))
    start!(agent_loop)
    run!(agent_loop, "round1", sse_success("running", tool_calls: [
      { id: "call_round1_0", name: "bash", arguments: { command: "x" }.to_json },
    ]))
    assert_equal %w[dispatched absorb], node(agent_loop, "r1t0").values_at(:status, :on_failure)

    call = expire_claimed!(agent_loop, "r1t0")
    assert_nil call.failure_resolution, "absorb resolves by policy, never by a stamp"
    assert_equal :resolved, AgentLoops::Graph.settlement_of(call)
    assert_equal "running", agent_loop.reload.status, "an absorbed expiry holds nothing"
    assert_nil agent_loop.attention_reason

    schedule!(agent_loop)
    assert_equal "running", node(agent_loop, "r1").status, "the continuation was released"
    run!(agent_loop, "r1", sse_success("noted"))
    pairing = AgentLoops::RoundReplay::Pairing
    expected = "#{pairing::ERROR_OPEN}#{pairing::REASONS.fetch("uncertain")} (tool_uncertain) " \
      "#{AgentLoops::Parks::Settle::UNCERTAIN_DETAIL}#{pairing::ERROR_CLOSE}"
    assert_equal expected, paired_results(agent_loop, "r1").fetch("call_round1_0")
    assert_equal "completed", agent_loop.reload.status
  end
end
