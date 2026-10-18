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

  def start!(run, acting_user: @human)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: acting_user))
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  def claim!(run, key, executor: suite_runner)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: key, executor: executor
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def commit(run, key, token, executor: suite_runner, **over)
    Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: key, executor: executor, claim_token: token,
      **{ content: "done", structured_content: nil, result_type: nil, outcome: "completed",
          is_error: false, title: nil, metadata: nil }.merge(over)
    ))
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)

  test "conversation archive preserves accepted tool claim renewal and final commit" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: suite_runner)
    run = create_answered_loop(tool("alpha"), conversation: conversation, acting_user: @human)
    assert_predicate Conversations::Archive.call(conversation: conversation), :accepted?

    token = claim!(run, "alpha")
    renewed = Executors::Extend.call(Executors::Extend::Command.new(run: run,
      task_key: "alpha", executor: suite_runner, claim_token: token, timeout_ms: 1_000))
    assert_predicate renewed, :accepted?
    assert_predicate commit(run, "alpha", token), :applied?
    assert_equal "completed", node(run, "alpha").status
    assert_predicate conversation.reload, :archived?
  end

  test "a private Runner reconciles its accepted claim after the Agent changes steward" do
    agent = users(:agent)
    runner = connect_runner(manager: users(:owner), assignment_agent: agent).executor_access_token.executor
    assert_predicate runner.announce(tools: [{ "name" => "read_file",
      "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }]), :accepted?
    run = seed(tool("private-read"), creating_user: agent, default_runner_executor_public_id: runner.public_id)
    start!(run, acting_user: agent)
    token = claim!(run, "private-read", executor: runner)
    assert_equal :changed, agent.change_steward(to: users(:member))
    refute runner.reload.eligible_for?(agent)

    renewed = Executors::Extend.call(Executors::Extend::Command.new(run: run,
      task_key: "private-read", executor: runner, claim_token: token, timeout_ms: 1_000))
    assert_predicate renewed, :accepted?
    assert_predicate commit(run, "private-read", token, executor: runner), :applied?
    assert_equal "completed", node(run, "private-read").status
  end

  def second_runner
    @second_runner ||= connect_runner(
      manager: users(:owner), registration_identifier: "test-runner-2",
      display_name: "Second runner", assignment_scope: :account_wide
    ).executor_access_token.executor
  end

  test "the address proves the door: another executor holding the token is not_addressed_here" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")

    result = commit(run, "alpha", token, executor: second_runner)
    assert_equal :not_addressed_here, result.outcome
    assert_equal "dispatched", node(run, "alpha").status, "refused before the token was read"
  end

  # A pool row is committed by its claimant only: another member holding the token is refused at the
  # fence, and a member that never claimed it answers the same word before Settle's `stale_claim`.
  test "a pool row is committed by its claimant alone" do
    first = connect_provider(identifier: "pool-a", tools: ["net_fetch"])
    second = connect_provider(identifier: "pool-b", tools: ["net_fetch"])
    run = seed(tool("fetch", "net_fetch"))
    start!(run)
    assert_equal :not_addressed_here, commit(run, "fetch", nil, executor: first).outcome,
      "unclaimed: nobody's yet"
    token = claim!(run, "fetch", executor: first)

    assert_equal :not_addressed_here, commit(run, "fetch", token, executor: second).outcome
    assert_equal :not_addressed_here, commit(run, "fetch", token).outcome, "the bound runner is no member"
    assert_equal "dispatched", node(run, "fetch").status

    result = commit(run, "fetch", token, executor: first)
    assert_predicate result, :applied?
    assert_equal "completed", node(run, "fetch").status
  end

  test "an executor that lost its eligibility since the claim is not_eligible" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")
    suite_runner.revoke

    assert_equal :not_eligible, commit(run, "alpha", token).outcome
    assert_equal "dispatched", node(run, "alpha").status
  end

  # The dedication fence rides inside `data_writable_by?` (access.rb) and is
  # read of the loop's frozen principal at commit as at claim.
  test "the loop's principal losing write standing after the claim is not_authorized" do
    run = seed(tool("alpha"), creating_user: users(:agent))
    start!(run, acting_user: users(:agent))
    token = claim!(run, "alpha")
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "someone-else")

    assert_equal :not_authorized, commit(run.reload, "alpha", token).outcome
    assert_equal "dispatched", node(run, "alpha").status
  end

  test "a missing key and a tombstoned loop are not_found" do
    run = seed(tool("alpha"))
    start!(run)
    assert_equal :not_found, commit(run, "nope", "x").outcome

    Run.where(id: run.id).update_all(status: "completed", tombstoned_at: Time.current)
    assert_equal :not_found, commit(run.reload, "alpha", "x").outcome
  end

  test "Settle's answers pass through: applied, idle on the second commit, stale_claim, the deadline" do
    run = seed(tool("alpha"))
    start!(run)
    token = claim!(run, "alpha")

    assert_equal :stale_claim, commit(run, "alpha", "not-the-token").outcome
    assert_equal :applied, commit(run, "alpha", token).outcome
    assert_equal "completed", node(run, "alpha").status
    assert_equal :idle, commit(run, "alpha", token, content: "again").outcome,
      "write-once: the second commit under the same token settles nothing and refuses nothing"
    assert_equal "completed", node(run, "alpha").status

    late_loop = seed(tool("beta"))
    start!(late_loop)
    late_token = claim!(late_loop, "beta")
    Task.where(id: node(late_loop, "beta").id).update_all(await_started_at: 2.hours.ago)
    assert_equal :applied, commit(late_loop, "beta", late_token, content: "too late").outcome
    assert_predicate node(late_loop, "beta"), :terminal?, "the deadline wins"
    assert_equal "timed_out", node(late_loop, "beta").status, "read_file is replayable: a plain timeout"
    assert_nil node(late_loop, "beta").output_preview, "and the late content is discarded"
  end

  # AN ASK ON THE EXECUTOR PLANE: the finder reaches the parked row of either type and the address
  # fence reads it first, so another executor gets `not_addressed_here` exactly as on a tool row;
  # the addressee itself is refused by kind, because an ask is a person's to answer on the member
  # resolution door, and the executor door settles tool calls alone.
  def agent_address = (@agent_address ||= Executor.address_for(users(:agent)))

  def asking_loop(creating_user: users(:agent))
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]), creating_user: creating_user)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: creating_user))
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
    [run, run.tasks.where(type: Tasks::AwaitTask.sti_name).sole]
  end

  test "an ask is not_addressed_here for another executor and not_claimable_kind for its addressee" do
    run, asked = asking_loop
    key = asked.node_key

    assert_equal :not_addressed_here, commit(run, key, nil, executor: suite_runner).outcome,
      "another executor of the account gets the same word a tool row gives it"
    assert_equal "awaiting_input", asked.reload.status

    ensure_ready_address!
    assert_equal :not_claimable_kind, commit(run.reload, key, nil, executor: agent_address).outcome,
      "the addressee is refused by kind: an ask is answered on the member plane"
    assert_equal :not_claimable_kind,
      commit(run, key, nil, executor: agent_address, content: "Postgres", outcome: "failed").outcome,
      "no outcome commits an ask here"
    assert_equal "awaiting_input", asked.reload.status, "the executor door settles no ask"

    resolved = Runs::Parks::Settle.call(node: asked, claim_token: nil, content: "Postgres",
      creator: users(:agent), resolved_by: nil)
    assert_predicate resolved, :applied?, "the person's door settles the same row"
    assert_equal "completed", asked.reload.status
    assert_equal "Postgres", asked.content_bodies.find_by!(role: "output").effective_text
  end

  test "an unclaimed ask whose address is revoked is settled by the park sweep as executor_revoked" do
    ensure_ready_address!
    other_loop, other = asking_loop
    agent_address.revoke
    assert_equal :not_claimable_kind, commit(other_loop, other.node_key, nil, executor: agent_address.reload).outcome,
      "kind is read before eligibility, so the refusal does not change with the address"
    assert_equal "awaiting_input", other.reload.status, "transport is fenced before task cleanup"
    perform_enqueued_jobs(only: Runs::Parks::TimeoutSweepJob)
    assert_equal %w[failed executor_revoked], other.reload.values_at(:status, :error_key),
      "the asynchronous park sweep settles the unclaimed ask"
  end

  test "a tokened await's key is not_addressed_here on the executor plane, never settled" do
    ensure_ready_address!
    run = seed(ask("gate"), creating_user: users(:agent))
    start!(run, acting_user: users(:agent))
    gate = node(run, "gate")
    assert_equal "dispatched", gate.status

    assert_equal :not_addressed_here, commit(run, "gate", nil, executor: agent_address).outcome
    assert_equal :not_addressed_here, commit(run, "gate", gate.resolution_token, executor: agent_address).outcome
    assert_equal "dispatched", gate.reload.status
  end

  # The address answers eligibility only when a transport credential is ready for it; the unit
  # fixtures hold none until asked.
  def ensure_ready_address!
    return if Executor.credential_readiness_for([agent_address]).fetch(agent_address.id) == :ready

    create_bound_credential(executor: agent_address, name: "Lane transport")
  end

  # The deadline wins on a WRITE too, and by the same expiry rule: the holder's own late answer on a
  # non-replayable call is not trusted either — the row reads `uncertain`, its content discarded,
  # and the detail is the sentence an adjudicator and the model read.
  test "a late commit on a claimed write call settles uncertain, content discarded" do
    late_loop = seed({ "tool" => { "key" => "job", "name" => "bash", "route" => { "kind" => "runner" }, "input" => { "command" => "x" } } })
    start!(late_loop)
    late_token = claim!(late_loop, "job")
    Task.where(id: node(late_loop, "job").id).update_all(await_started_at: 2.hours.ago)

    assert_equal :applied, commit(late_loop, "job", late_token, content: "too late").outcome
    row = node(late_loop, "job")
    assert_predicate row, :terminal?, "the deadline wins"
    assert_equal %w[uncertain tool_uncertain], row.values_at(:status, :error_key)
    assert_equal Runs::Parks::Settle::UNCERTAIN_DETAIL, row.error_detail
    assert_nil row.output_preview, "the late content is discarded"
    assert_equal 0, row.content_bodies.where(role: "output").count
  end

  # THE TWO WORDS OF THE FENCE: eligibility for the loop's ANSWERER, write standing of its SPEAKER —
  # the split the claim pins, re-read at commit.
  test "the commit judges the executor for the loop's answerer, and the standing of its speaker" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private")
      .executor_access_token.executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent),
      default_runner_executor: owners_private)
    run = create_answered_loop(tool("alpha"), conversation: answered, acting_user: @human)
    token = claim!(run, "alpha", executor: owners_private)

    Workspace.where(id: @workspace.id).update_all(access_mode: "private")
    assert_equal :not_authorized, commit(run.reload, "alpha", token, executor: owners_private).outcome,
      "the SPEAKER's standing keeps the loop writing"
    assert_equal "dispatched", node(run, "alpha").status

    Workspace.where(id: @workspace.id).update_all(access_mode: "account_wide")
    assert_predicate commit(run.reload, "alpha", token, executor: owners_private), :applied?
    assert_equal "completed", node(run, "alpha").status
  end

  test "the commit judges the executor for the TURN's answerer" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private")
      .executor_access_token.executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    plain = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: owners_private)
    run = create_answered_loop(tool("alpha"), conversation: plain, acting_user: @human, answering_user: users(:agent))
    token = claim!(run, "alpha", executor: owners_private)

    assert_predicate commit(run.reload, "alpha", token, executor: owners_private), :applied?
    assert_equal "completed", node(run, "alpha").status
  end
end
