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
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read_file", **over)
    fields = { "key" => key, "name" => name }.merge(over)
    fields["route"] = { "kind" => "runner", "runner_executor_public_id" => @delivery_runner.public_id } if @delivery_runner
    { "tool" => fields }
  end

  def model(key, **over)
    { "model" => { "key" => key, "model" => MOCK_MODEL, "prompt" => "p",
      "tools" => [Nexus::ToolRegistry.function_definition("wait"), declared("read_file")] }.merge(over) }
  end

  def declared(name)
    declaration = { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
    declaration["route"] = { "kind" => "runner", "runner_executor_public_id" => @delivery_runner.public_id,
      "tool_name" => name } if @delivery_runner
    declaration
  end

  def start!(agent_run, acting_user: users(:owner))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: acting_user))
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def step_attempt(agent_run, key)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == node(agent_run, key).selected_model_invocation_id
    end
    raise "#{key} not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  # A round calling `read_file` once: the fan member is addressed and the
  # continuation waits on it.
  def fan!(agent_run, key: "round1")
    apply_via(step_attempt(agent_run, key), sse_success("calling", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read")
  end

  # A machine of `kind` under the member — made an admin so the machine can be account-wide and
  # serve the OWNER's loops: the loop's principal must outlive its executor's manager, or the
  # scheduler's own standing cut (a removed creator stops the loop) would be what this suite sees.
  # Runner declarations choose this fixture target before acceptance.
  def machine(kind, identifier: "member-#{kind}")
    assert_equal :role_changed, @human.change_role(to: :admin)
    connection = connect_runner(
      manager: @human, registration_identifier: identifier, assignment_scope: :account_wide, executor_kind: kind
    )
    executor = connection.executor_access_token.task_executor
    @delivery_runner = executor if kind == :runner
    (@secrets ||= {})[executor.id] = connection.executor_access_secret
    assert_predicate executor.announce(tools: TEST_SERVED_TOOLS), :accepted?
    executor
  end

  def transport_secret_for(executor) = @secrets.fetch(executor.id)

  def claim!(agent_run, key, executor)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: executor
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def settle!(node, token)
    assert_predicate AgentRuns::Parks::Settle.call(
      node: node.reload, claim_token: token, content: "done", outcome: "completed"
    ), :applied?
  end

  # Revocation fences transport first, then wakes the same bounded recovery
  # that settles Human shutdown. Claimed work keeps its effect-profile clock.
  test "a revoke fails the unclaimed rows addressed to the executor, and leaves a claimed row to its deadline" do
    runner = machine(:runner)
    agent_run = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"),
      creating_user: users(:owner))
    start!(agent_run)
    call = fan!(agent_run)
    assert_equal runner.id, call.addressed_executor_id

    claimed_loop = seed(model("round1", "prompt" => "go"), creating_user: users(:owner))
    start!(claimed_loop)
    claimed = fan!(claimed_loop)
    claim!(claimed_loop, claimed.node_key, runner)

    assert_enqueued_with(job: AgentRuns::Parks::TimeoutSweepJob) do
      assert_equal :revoked, runner.revoke
    end
    assert_not runner.transport_authorized_at?(runner.credential_epoch)
    assert_equal "dispatched", call.reload.status, "authority cut does not walk task rows"
    perform_enqueued_jobs(only: AgentRuns::Parks::TimeoutSweepJob)
    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)

    assert_equal %w[failed executor_revoked], call.reload.values_at(:status, :error_key)
    assert_equal "running", node(agent_run, "r1").status, "the absorb fan continues past the failed member"
    assert_equal "dispatched", claimed.reload.status, "a claimed row finishes or expires where it was claimed"
    assert_equal :revoked, runner.reload.revoke, "a repeat is a no-op"
  end

  test "human removal fails the unclaimed rows addressed to its runner as executor_revoked, and the absorb fan continues" do
    runner = machine(:runner)
    agent_run = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"),
      creating_user: users(:owner))
    start!(agent_run)
    call = fan!(agent_run)
    assert_equal runner.id, call.addressed_executor_id
    assert_equal "dispatched", call.status

    assert_equal :removed, @human.remove
    assert_equal "dispatched", call.reload.status, "removal is O(1); the pass is convergence's"
    AgentRuns::Parks::TimeoutSweep.call
    TaskExecutor.converge
    # The pass wakes the scheduler (level-triggered), which starts what
    # the settlement released.
    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)

    call.reload
    assert_equal "failed", call.status, "the same shape as tool_not_served at start"
    assert_equal "executor_revoked", call.error_key
    assert_nil call.failure_resolution, "absorb resolves by policy, never by a stamp"
    assert_equal :resolved, AgentRuns::Graph.settlement_of(call), "a fan member resolves, so the round continues"
    assert_equal "running", node(agent_run, "r1").status, "the continuation is released, not stranded"
    assert_equal @human.reload.managed_resource_shutdown_generation,
      runner.reload.applied_human_shutdown_generation, "nothing claimed: the epoch advanced"
    assert_equal 2, runner.credential_epoch
  end

  test "Agent removal leaves approval cleanup to the asynchronous force stop" do
    announce_tools!(@agent, %w[read_file])
    address = TaskExecutor.address_for(@agent)
    agent_run = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"),
      creating_user: @agent, approval_mode: "ask")
    start!(agent_run, acting_user: @agent)
    call = fan!(agent_run)
    assert_equal "needs_approval", call.status
    assert_equal address.id, call.addressed_executor_id

    assert_equal :removed, @agent.remove
    assert_equal "needs_approval", call.reload.status
    assert_equal address.id, call.addressed_executor_id
    Users::StopAgentWorkJob.perform_now(@agent.id)

    assert_equal %w[canceled run_canceled], call.reload.values_at(:status, :error_key)
    assert_not_nil call.effect_profile
    assert_not_predicate AgentRuns::Tasks::Approve.call(AgentRuns::Tasks::Approve::Command.new(
      agent_run: agent_run, task_key: call.node_key, acting_user: users(:owner)
    )), :accepted?
    assert_equal "canceled", call.reload.status
  end

  test "a propagate row failed by the pass skips its successors, as any failure of it would" do
    runner = machine(:runner)
    agent_run = seed(tool("t", "on_failure" => "propagate"), model("after", "prompt" => "then"),
      creating_user: users(:owner))
    start!(agent_run)

    assert_equal :removed, @human.remove
    AgentRuns::Parks::TimeoutSweep.call
    TaskExecutor.converge

    assert_equal %w[failed executor_revoked], node(agent_run, "t").values_at(:status, :error_key)
    assert_nil node(agent_run, "t").failure_resolution
    assert_equal "skipped", node(agent_run, "after").status
  end

  # THE PROMISE THE PASS ALWAYS MADE, NOW KEPT: a `halt` row the executor
  # left behind holds the loop for a person — `canceled` read as a skip
  # and let the loop complete past a failure nobody adjudicated.
  test "a halted retry preserves its revoked target and refuses redispatch" do
    runner = machine(:runner)
    agent_run = seed(tool("t", "on_failure" => "halt"), model("after", "prompt" => "then"),
      creating_user: users(:owner))
    start!(agent_run)

    assert_equal :removed, @human.remove
    AgentRuns::Parks::TimeoutSweep.call
    TaskExecutor.converge
    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)

    held = node(agent_run, "t")
    assert_equal %w[failed executor_revoked], held.values_at(:status, :error_key)
    assert_equal :pending, AgentRuns::Graph.settlement_of(held)
    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "halt_failure", agent_run.attention_reason
    assert_equal "queued", node(agent_run, "after").status, "nothing downstream moved"
    generation = held.execution_generation
    assert_predicate Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: agent_run, executor_public_id: suite_runner.public_id, acting_user: users(:owner)
    )), :accepted?
    assert_predicate AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "t", acting_user: users(:owner)
    )), :accepted?, "a person may re-run it under a new generation"
    assert_equal generation + 1, held.reload.execution_generation
    assert_equal runner.public_id, held.target_executor_public_id
    schedule!(agent_run)
    assert_equal %w[failed tool_not_served], held.reload.values_at(:status, :error_key)
    refute_equal suite_runner.id, held.addressed_executor_id
  end

  test "the epoch waits on a claimed row and advances once it settles" do
    runner = machine(:runner)
    agent_run = seed(parallel(tool("held"), tool("loose")), tool("gamma"), creating_user: users(:owner))
    start!(agent_run)
    token = claim!(agent_run, "held", runner)
    transport = runner.access_tokens.sole

    assert_equal :removed, @human.remove
    assert_predicate runner.reload, :holds_claimed_work?
    AgentRuns::Parks::TimeoutSweep.call
    TaskExecutor.converge

    assert_equal "failed", node(agent_run, "loose").status, "the unclaimed sibling is failed now"
    held = node(agent_run, "held")
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
    agent_run = seed(parallel(tool("held"), tool("loose")), tool("gamma"), creating_user: users(:owner))
    agent_run.update!(default_runner_executor: nil)
    start!(agent_run)
    assert_equal "tool_provider", node(agent_run, "held").addressed_role
    token = claim!(agent_run, "held", provider)

    assert_equal :removed, @human.remove
    TaskExecutor.converge

    assert_equal "dispatched", node(agent_run, "loose").status, "a pool row is nobody's to cancel"
    assert_equal 1, provider.reload.credential_epoch
    assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "loose", executor: other
    )), :accepted?, "another member takes it"

    settle!(node(agent_run, "held"), token)
    TaskExecutor.converge
    assert_equal 2, provider.reload.credential_epoch
  end

  test "Agent removal asynchronously cancels both unclaimed and claimed work" do
    announce_tools!(@agent, %w[agent_read agent_held])
    address = TaskExecutor.address_for(@agent)
    agent_run = seed(parallel(tool("loose", "agent_read"), tool("held", "agent_held")), tool("gamma"),
      creating_user: @agent)
    start!(agent_run, acting_user: @agent)
    assert_equal address.id, node(agent_run, "loose").addressed_executor_id
    claim!(agent_run, "held", address)

    assert_equal :removed, @agent.remove

    assert_equal "dispatched", node(agent_run, "loose").status
    assert_equal "dispatched", node(agent_run, "held").status
    Users::StopAgentWorkJob.perform_now(@agent.id)
    assert_equal %w[canceled run_canceled], node(agent_run, "loose").values_at(:status, :error_key)
    assert_equal %w[canceled run_canceled], node(agent_run, "held").values_at(:status, :error_key)
  end

  test "the pass is idempotent and touches nothing on a terminal loop" do
    runner = machine(:runner)
    agent_run = seed(tool("t"), creating_user: users(:owner))
    start!(agent_run)
    AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: agent_run, acting_user: users(:owner)))
    assert_equal "run_canceled", node(agent_run, "t").error_key

    runner.revoke
    2.times { assert_equal 0, AgentRuns::Parks::TimeoutSweep.call.counts.fetch(:revoked) }
    assert_equal "run_canceled", node(agent_run, "t").error_key
  end
end
