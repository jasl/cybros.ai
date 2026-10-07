require "test_helper"

# The executor plane's commit: a scoped finder and three level-triggered fences, lock-free, then ONE
# `Parks::Settle` call — the engine untouched, so its answers pass through: write-once, `idle` under
# the same token after the settle, `stale_claim` for a dead token, and the deadline wins.
class Executors::CommitTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read_file", **over) = super(key, name, "input" => { "path" => key }, **over)

  def start!(agent_run, acting_user: @human)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: acting_user))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def claim!(agent_run, key, executor: suite_runner)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: executor
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def commit(agent_run, key, token, executor: suite_runner, **over)
    Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: key, executor: executor, claim_token: token,
      **{ content: "done", structured_content: nil, result_type: nil, outcome: "completed",
          is_error: false, title: nil, metadata: nil }.merge(over)
    ))
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def second_runner
    @second_runner ||= connect_runner(
      manager: users(:owner), registration_identifier: "test-runner-2",
      display_name: "Second runner", assignment_scope: :account_wide
    ).executor_access_token.task_executor
  end

  test "the address proves the door: another executor holding the token is not_addressed_here" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    token = claim!(agent_run, "alpha")

    result = commit(agent_run, "alpha", token, executor: second_runner)
    assert_equal :not_addressed_here, result.outcome
    assert_equal "dispatched", node(agent_run, "alpha").status, "refused before the token was read"
  end

  # A pool row is committed by its claimant only: another member holding the token is refused at the
  # fence, and a member that never claimed it answers the same word before Settle's `stale_claim`.
  test "a pool row is committed by its claimant alone" do
    first = connect_provider(identifier: "pool-a", tools: ["net_fetch"])
    second = connect_provider(identifier: "pool-b", tools: ["net_fetch"])
    agent_run = seed(tool("fetch", "net_fetch"))
    start!(agent_run)
    assert_equal :not_addressed_here, commit(agent_run, "fetch", nil, executor: first).outcome,
      "unclaimed: nobody's yet"
    token = claim!(agent_run, "fetch", executor: first)

    assert_equal :not_addressed_here, commit(agent_run, "fetch", token, executor: second).outcome
    assert_equal :not_addressed_here, commit(agent_run, "fetch", token).outcome, "the bound runner is no member"
    assert_equal "dispatched", node(agent_run, "fetch").status

    result = commit(agent_run, "fetch", token, executor: first)
    assert_predicate result, :applied?
    assert_equal "completed", node(agent_run, "fetch").status
  end

  test "an executor that lost its eligibility since the claim is not_eligible" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    token = claim!(agent_run, "alpha")
    suite_runner.revoke

    assert_equal :not_eligible, commit(agent_run, "alpha", token).outcome
    assert_equal "dispatched", node(agent_run, "alpha").status
  end

  # The dedication fence rides inside `data_writable_by?` (access.rb) and is
  # read of the loop's frozen principal at commit as at claim.
  test "the loop's principal losing write standing after the claim is not_authorized" do
    agent_run = seed(tool("alpha"), creating_user: users(:agent))
    start!(agent_run, acting_user: users(:agent))
    token = claim!(agent_run, "alpha")
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "someone-else")

    assert_equal :not_authorized, commit(agent_run.reload, "alpha", token).outcome
    assert_equal "dispatched", node(agent_run, "alpha").status
  end

  test "a missing key and a tombstoned loop are not_found" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    assert_equal :not_found, commit(agent_run, "nope", "x").outcome

    AgentRun.where(id: agent_run.id).update_all(status: "completed", tombstoned_at: Time.current)
    assert_equal :not_found, commit(agent_run.reload, "alpha", "x").outcome
  end

  test "Settle's answers pass through: applied, idle on the second commit, stale_claim, the deadline" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    token = claim!(agent_run, "alpha")

    assert_equal :stale_claim, commit(agent_run, "alpha", "not-the-token").outcome
    assert_equal :applied, commit(agent_run, "alpha", token).outcome
    assert_equal "completed", node(agent_run, "alpha").status
    assert_equal :idle, commit(agent_run, "alpha", token, content: "again").outcome,
      "write-once: the second commit under the same token settles nothing and refuses nothing"
    assert_equal "completed", node(agent_run, "alpha").status

    late_loop = seed(tool("beta"))
    start!(late_loop)
    late_token = claim!(late_loop, "beta")
    AgentRunTask.where(id: node(late_loop, "beta").id).update_all(await_started_at: 2.hours.ago)
    assert_equal :applied, commit(late_loop, "beta", late_token, content: "too late").outcome
    assert_predicate node(late_loop, "beta"), :terminal?, "the deadline wins"
    assert_equal "timed_out", node(late_loop, "beta").status, "read_file is replayable: a plain timeout"
    assert_nil node(late_loop, "beta").output_preview, "and the late content is discarded"
  end

  # THE ASK ON THE EXECUTOR PLANE: the finder reaches the parked row of either type; the fence is
  # unchanged, so the address proves the door — a tokenless commit from the executor the row names
  # settles the ask through Settle's own tokenless-await rule, and the three refusals answer exactly
  # as they do on a tool row.
  def agent_address = (@agent_address ||= TaskExecutor.address_for(users(:agent)))

  def asking_loop(creating_user: users(:agent))
    agent_run = seed(model("round1", "tools" => [Nexus::Tools::ASK]), creating_user: creating_user)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: creating_user))
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
    [agent_run, agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole]
  end

  test "an ask commits on its addressee's credential with no token, and the fence refuses the rest" do
    agent_run, asked = asking_loop
    key = asked.node_key

    assert_equal :not_addressed_here, commit(agent_run, key, nil, executor: suite_runner).outcome,
      "another executor of the account gets the same word a tool row gives it"
    assert_equal "awaiting_input", asked.reload.status

    ensure_ready_address!
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "someone-else")
    assert_equal :not_authorized, commit(agent_run.reload, key, nil, executor: agent_address).outcome,
      "the principal's lost standing is level-triggered here as at the claim"
    Workspace.where(id: @workspace.id).update_all(agent_identifier: nil)

    result = commit(agent_run.reload, key, nil, executor: agent_address, content: "Postgres")
    assert_predicate result, :applied?, result.outcome.inspect
    assert_equal "completed", asked.reload.status
    assert_equal "Postgres", asked.content_bodies.find_by!(role: "output").effective_text
    assert_equal :idle, commit(agent_run, key, nil, executor: agent_address, content: "again").outcome

    other_loop, other = asking_loop
    agent_address.revoke
    assert_equal :not_eligible, commit(other_loop, other.node_key, nil, executor: agent_address.reload).outcome,
      "an address revoked since the row was addressed answers as a revoked runner does"
    assert_equal "awaiting_input", other.reload.status, "transport is fenced before task cleanup"
    perform_enqueued_jobs(only: AgentRuns::Parks::TimeoutSweepJob)
    assert_equal %w[failed executor_revoked], other.reload.values_at(:status, :error_key),
      "the asynchronous park sweep settles the unclaimed ask"
  end

  test "an ask's failed outcome escalates through the await's own policy" do
    ensure_ready_address!
    agent_run, asked = asking_loop
    result = commit(agent_run, asked.node_key, nil, executor: agent_address,
      content: "cannot say", outcome: "failed")
    assert_predicate result, :applied?
    assert_equal %w[failed await_failed], asked.reload.values_at(:status, :error_key)
  end

  test "a tokened await's key is not_addressed_here on the executor plane, never settled" do
    ensure_ready_address!
    agent_run = seed(ask("gate"), creating_user: users(:agent))
    start!(agent_run, acting_user: users(:agent))
    gate = node(agent_run, "gate")
    assert_equal "dispatched", gate.status

    assert_equal :not_addressed_here, commit(agent_run, "gate", nil, executor: agent_address).outcome
    assert_equal :not_addressed_here, commit(agent_run, "gate", gate.resolution_token, executor: agent_address).outcome
    assert_equal "dispatched", gate.reload.status
  end

  # The address answers eligibility only when a transport credential is ready for it; the unit
  # fixtures hold none until asked.
  def ensure_ready_address!
    return if TaskExecutor.credential_readiness_for([agent_address]).fetch(agent_address.id) == :ready

    create_bound_credential(executor: agent_address, name: "Lane transport")
  end

  # The deadline wins on a WRITE too, and by the same expiry rule: the holder's own late answer on a
  # non-replayable call is not trusted either — the row reads `uncertain`, its content discarded,
  # and the detail is the sentence an adjudicator and the model read.
  test "a late commit on a claimed write call settles uncertain, content discarded" do
    late_loop = seed({ "tool" => { "key" => "job", "name" => "bash", "route" => { "kind" => "runner" }, "input" => { "command" => "x" } } })
    start!(late_loop)
    late_token = claim!(late_loop, "job")
    AgentRunTask.where(id: node(late_loop, "job").id).update_all(await_started_at: 2.hours.ago)

    assert_equal :applied, commit(late_loop, "job", late_token, content: "too late").outcome
    row = node(late_loop, "job")
    assert_predicate row, :terminal?, "the deadline wins"
    assert_equal %w[uncertain tool_uncertain], row.values_at(:status, :error_key)
    assert_equal AgentRuns::Parks::Settle::UNCERTAIN_DETAIL, row.error_detail
    assert_nil row.output_preview, "the late content is discarded"
    assert_equal 0, row.content_bodies.where(role: "output").count
  end

  # THE TWO WORDS OF THE FENCE: eligibility for the loop's ANSWERER, write standing of its SPEAKER —
  # the split the claim pins, re-read at commit.
  test "the commit judges the executor for the loop's answerer, and the standing of its speaker" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private")
      .executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent),
      default_runner_executor: owners_private)
    agent_run = create_answered_loop(tool("alpha"), conversation: answered, acting_user: @human)
    token = claim!(agent_run, "alpha", executor: owners_private)

    Workspace.where(id: @workspace.id).update_all(access_mode: "private")
    assert_equal :not_authorized, commit(agent_run.reload, "alpha", token, executor: owners_private).outcome,
      "the SPEAKER's standing keeps the loop writing"
    assert_equal "dispatched", node(agent_run, "alpha").status

    Workspace.where(id: @workspace.id).update_all(access_mode: "account_wide")
    assert_predicate commit(agent_run.reload, "alpha", token, executor: owners_private), :applied?
    assert_equal "completed", node(agent_run, "alpha").status
  end

  test "the commit judges the executor for the TURN's answerer" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private")
      .executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    plain = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: owners_private)
    agent_run = create_answered_loop(tool("alpha"), conversation: plain, acting_user: @human, answering_user: users(:agent))
    token = claim!(agent_run, "alpha", executor: owners_private)

    assert_predicate commit(agent_run.reload, "alpha", token, executor: owners_private), :applied?
    assert_equal "completed", node(agent_run, "alpha").status
  end
end
