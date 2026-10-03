require "test_helper"

# The two removal passes: when a Human is removed, every machine it manages — a runner, a tools
# provider — and every agent address its stewarded Profiles hold, converge in two level-triggered
# steps. (i) Per loop, under the loop lock, the executor's UNCLAIMED addressed rows are FAILED
# `executor_revoked` through FailNode's own default rule — one narrated transition each: an absorb
# fan continues, a propagate row skips its successors, a halt row HOLDS the loop. (ii) The executor
# acknowledges and advances its epoch only when no non-terminal row is claimed by it: a claimed row
# reaches its deadline and settles by its profile on the credential that took it. Agent-profile
# removal no longer runs pass (i) from `User#remove`: the removal transaction fences the member and
# executor credential planes, and `Users::StopAgentWork` stops the related conversations and live
# loops after commit (`app/services/users/stop_agent_work.rb`).
class TaskExecutor::RemovalPassesTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read_file", **over) = super(key, name, **over)

  def model(key, **over)
    super(key, "tools" => [Nexus::Compose::DEFINITION, declared("read_file")], **over)
  end

  def declared(name)
    { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
  end

  def start!(agent_loop, acting_user: users(:owner))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: acting_user))
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  def schedule!(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def step_attempt(agent_loop, key)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == node(agent_loop, key).selected_model_invocation_id
    end
    raise "#{key} not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  # A round calling `read_file` once: the fan member is addressed and the
  # continuation waits on it.
  def fan!(agent_loop, key: "round1")
    apply_via(step_attempt(agent_loop, key), sse_success("calling", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
    agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_read")
  end

  # A machine of `kind` under the member — made an admin so the machine can be account-wide and
  # serve the OWNER's loops: the loop's principal must outlive its executor's manager, or the
  # scheduler's own standing cut (a removed creator stops the loop) would be what this suite sees.
  # The binding is moved by hand.
  def machine(kind, identifier: "member-#{kind}")
    assert_equal :role_changed, @human.change_role(to: :admin)
    connection = connect_runner(
      manager: @human, runner_identifier: identifier, assignment_scope: :account_wide, executor_kind: kind
    )
    executor = connection.executor_access_token.task_executor
    (@secrets ||= {})[executor.id] = connection.executor_access_secret
    assert_predicate executor.announce(tools: TEST_SERVED_TOOLS), :accepted?
    executor
  end

  def transport_secret_for(executor) = @secrets.fetch(executor.id)

  def claim!(agent_loop, key, executor)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: key, executor: executor
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def settle!(node, token)
    assert_predicate AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: token, content: "done", outcome: "completed"
    ), :applied?
  end

  # Revocation fences transport first, then wakes the same bounded recovery
  # that settles Human shutdown. Claimed work keeps its effect-profile clock.
  test "a revoke fails the unclaimed rows addressed to the executor, and leaves a claimed row to its deadline" do
    runner = machine(:runner)
    agent_loop = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"),
      creating_user: users(:owner))
    agent_loop.update!(runner_executor: runner)
    start!(agent_loop)
    call = fan!(agent_loop)
    assert_equal runner.id, call.addressed_executor_id

    claimed_loop = seed(model("round1", "prompt" => "go"), creating_user: users(:owner))
    claimed_loop.update!(runner_executor: runner)
    start!(claimed_loop)
    claimed = fan!(claimed_loop)
    claim!(claimed_loop, claimed.node_key, runner)

    assert_enqueued_with(job: AgentLoops::Parks::TimeoutSweepJob) do
      assert_equal :revoked, runner.revoke
    end
    assert_not runner.transport_authorized_at?(runner.credential_epoch)
    assert_equal "dispatched", call.reload.status, "authority cut does not walk task rows"
    perform_enqueued_jobs(only: AgentLoops::Parks::TimeoutSweepJob)
    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)

    assert_equal %w[failed executor_revoked], call.reload.values_at(:status, :error_key)
    assert_equal "running", node(agent_loop, "r1").status, "the absorb fan continues past the failed member"
    assert_equal "dispatched", claimed.reload.status, "a claimed row finishes or expires where it was claimed"
    assert_equal :revoked, runner.reload.revoke, "a repeat is a no-op"
  end

  test "human removal fails the unclaimed rows addressed to its runner as executor_revoked, and the absorb fan continues" do
    runner = machine(:runner)
    agent_loop = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"),
      creating_user: users(:owner))
    agent_loop.update!(runner_executor: runner)
    start!(agent_loop)
    call = fan!(agent_loop)
    assert_equal runner.id, call.addressed_executor_id
    assert_equal "dispatched", call.status

    assert_equal :removed, @human.remove
    assert_equal "dispatched", call.reload.status, "removal is O(1); the pass is convergence's"
    AgentLoops::Parks::TimeoutSweep.call
    TaskExecutor.converge
    # The pass wakes the scheduler (level-triggered), which starts what
    # the settlement released.
    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)

    call.reload
    assert_equal "failed", call.status, "the same shape as tool_not_served at start"
    assert_equal "executor_revoked", call.error_key
    assert_nil call.failure_resolution, "absorb resolves by policy, never by a stamp"
    assert_equal :resolved, AgentLoops::Graph.settlement_of(call), "a fan member resolves, so the round continues"
    assert_equal "running", node(agent_loop, "r1").status, "the continuation is released, not stranded"
    assert_equal @human.reload.managed_resource_shutdown_generation,
      runner.reload.applied_human_shutdown_generation, "nothing claimed: the epoch advanced"
    assert_equal 2, runner.credential_epoch
  end

  test "Agent removal leaves approval cleanup to the asynchronous force stop" do
    address = TaskExecutor.address_for(@agent)
    agent_loop = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"),
      creating_user: @agent, approval_mode: "ask")
    start!(agent_loop, acting_user: @agent)
    call = fan!(agent_loop)
    assert_equal "needs_approval", call.status
    assert_equal address.id, call.addressed_executor_id

    assert_equal :removed, @agent.remove
    assert_equal "needs_approval", call.reload.status
    assert_equal address.id, call.addressed_executor_id
    Users::StopAgentWorkJob.perform_now(@agent.id)

    assert_equal %w[canceled loop_canceled], call.reload.values_at(:status, :error_key)
    assert_not_nil call.effect_profile
    assert_not_predicate AgentLoops::Tasks::Approve.call(AgentLoops::Tasks::Approve::Command.new(
      agent_loop: agent_loop, task_key: call.node_key, acting_user: users(:owner)
    )), :accepted?
    assert_equal "canceled", call.reload.status
  end

  test "a propagate row failed by the pass skips its successors, as any failure of it would" do
    runner = machine(:runner)
    agent_loop = seed(tool("t", "on_failure" => "propagate"), model("after", "prompt" => "then"),
      creating_user: users(:owner))
    agent_loop.update!(runner_executor: runner)
    start!(agent_loop)

    assert_equal :removed, @human.remove
    AgentLoops::Parks::TimeoutSweep.call
    TaskExecutor.converge

    assert_equal %w[failed executor_revoked], node(agent_loop, "t").values_at(:status, :error_key)
    assert_nil node(agent_loop, "t").failure_resolution
    assert_equal "skipped", node(agent_loop, "after").status
  end

  # THE PROMISE THE PASS ALWAYS MADE, NOW KEPT: a `halt` row the executor
  # left behind holds the loop for a person — `canceled` read as a skip
  # and let the loop complete past a failure nobody adjudicated.
  test "a halt row failed by the pass holds the loop for adjudication, and a retry re-addresses it" do
    runner = machine(:runner)
    agent_loop = seed(tool("t", "on_failure" => "halt"), model("after", "prompt" => "then"),
      creating_user: users(:owner))
    agent_loop.update!(runner_executor: runner)
    start!(agent_loop)

    assert_equal :removed, @human.remove
    AgentLoops::Parks::TimeoutSweep.call
    TaskExecutor.converge
    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)

    held = node(agent_loop, "t")
    assert_equal %w[failed executor_revoked], held.values_at(:status, :error_key)
    assert_equal :pending, AgentLoops::Graph.settlement_of(held)
    assert_equal "needs_attention", agent_loop.reload.status
    assert_equal "halt_failure", agent_loop.attention_reason
    assert_equal "queued", node(agent_loop, "after").status, "nothing downstream moved"
    assert_predicate AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "t", acting_user: users(:owner)
    )), :accepted?, "a person may re-run it under a new generation"
  end

  test "the epoch waits on a claimed row and advances once it settles" do
    runner = machine(:runner)
    agent_loop = seed(parallel(tool("held"), tool("loose")), tool("gamma"), creating_user: users(:owner))
    agent_loop.update!(runner_executor: runner)
    start!(agent_loop)
    token = claim!(agent_loop, "held", runner)
    transport = runner.access_tokens.sole

    assert_equal :removed, @human.remove
    assert_predicate runner.reload, :holds_claimed_work?
    AgentLoops::Parks::TimeoutSweep.call
    TaskExecutor.converge

    assert_equal "failed", node(agent_loop, "loose").status, "the unclaimed sibling is failed now"
    held = node(agent_loop, "held")
    assert_equal "dispatched", held.status, "a claimed row is left to its deadline and profile"
    assert_equal 1, runner.reload.credential_epoch, "the epoch waits"
    assert_predicate runner, :shutdown_pending?
    assert_equal transport, AccessToken.authenticate_executor_token(transport_secret_for(runner)),
      "the credential that took the work can still answer it"
    assert_equal :work_pending, runner.converge_human_shutdown(
      expected_human_id: @human.id,
      expected_generation: @human.reload.managed_resource_shutdown_generation,
      expected_applied_generation: runner.applied_human_shutdown_generation
    )

    settle!(held, token)
    TaskExecutor.converge

    assert_equal 2, runner.reload.credential_epoch
    assert_not_predicate runner, :shutdown_pending?
    assert_nil AccessToken.authenticate_executor_token(transport_secret_for(runner))
  end

  # A tools provider holds claimed POOL rows: pass (ii) gates on them the
  # same way; pass (i) never touches a pool row, which names no executor —
  # it stays in the pool for the other members.
  test "a tools provider's epoch waits on the pool row it claimed, and unclaimed pool rows stay in the pool" do
    assert_equal :role_changed, @human.change_role(to: :admin)
    provider = connect_provider(identifier: "member-provider", tools: TEST_SERVED_TOOLS, manager: @human)
    other = connect_provider(identifier: "pool-other", tools: %w[read_file])
    agent_loop = seed(parallel(tool("held"), tool("loose")), tool("gamma"), creating_user: users(:owner))
    agent_loop.update!(runner_executor: nil)
    start!(agent_loop)
    assert_equal "tools_provider", node(agent_loop, "held").addressed_role
    token = claim!(agent_loop, "held", provider)

    assert_equal :removed, @human.remove
    TaskExecutor.converge

    assert_equal "dispatched", node(agent_loop, "loose").status, "a pool row is nobody's to cancel"
    assert_equal 1, provider.reload.credential_epoch
    assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: "loose", executor: other
    )), :accepted?, "another member takes it"

    settle!(node(agent_loop, "held"), token)
    TaskExecutor.converge
    assert_equal 2, provider.reload.credential_epoch
  end

  test "Agent removal asynchronously cancels both unclaimed and claimed work" do
    announce_tools!(@agent, %w[agent_read agent_held])
    address = TaskExecutor.address_for(@agent)
    agent_loop = seed(parallel(tool("loose", "agent_read"), tool("held", "agent_held")), tool("gamma"),
      creating_user: @agent)
    start!(agent_loop, acting_user: @agent)
    assert_equal address.id, node(agent_loop, "loose").addressed_executor_id
    claim!(agent_loop, "held", address)

    assert_equal :removed, @agent.remove

    assert_equal "dispatched", node(agent_loop, "loose").status
    assert_equal "dispatched", node(agent_loop, "held").status
    Users::StopAgentWorkJob.perform_now(@agent.id)
    assert_equal %w[canceled loop_canceled], node(agent_loop, "loose").values_at(:status, :error_key)
    assert_equal %w[canceled loop_canceled], node(agent_loop, "held").values_at(:status, :error_key)
  end

  test "the pass is idempotent and touches nothing on a terminal loop" do
    runner = machine(:runner)
    agent_loop = seed(tool("t"), creating_user: users(:owner))
    agent_loop.update!(runner_executor: runner)
    start!(agent_loop)
    AgentLoops::Stop.call(AgentLoops::Stop::Command.forced(agent_loop: agent_loop, acting_user: users(:owner)))
    assert_equal "loop_canceled", node(agent_loop, "t").error_key

    runner.revoke
    2.times { assert_equal 0, AgentLoops::Parks::TimeoutSweep.call.counts.fetch(:revoked) }
    assert_equal "loop_canceled", node(agent_loop, "t").error_key
  end
end
