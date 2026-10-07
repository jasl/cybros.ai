require "test_helper"

# The executor plane's claim beside its lock site: the race test the ladder rule demands — claim vs
# sweep in all three orders — and the kinds a claim never takes: an ask and an approval are inbox
# rows with one answerer by construction, never a claimant.
class Executors::ClaimTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def claim(agent_run, key, executor: suite_runner)
    Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: executor
    ))
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def expire!(node) = AgentRunTask.where(id: node.id).update_all(await_started_at: 2.hours.ago)

  def sweep = AgentRuns::Parks::TimeoutSweep.call

  # (i) Sweep first: the expired claim settles; the claim then finds a terminal node and refuses
  # `task_not_claimable`. `alpha` is `read_file` — a READ_ONLY profile by the suite's vocabulary —
  # so its word is `timed_out` (a replayable claim's expiry is a plain timeout).
  test "sweep first: an expired claim is settled, and the claim after it is task_not_claimable" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    assert_predicate claim(agent_run, "alpha"), :accepted?
    expire!(node(agent_run, "alpha"))

    assert_equal 1, sweep[:expired]
    assert_equal %w[timed_out tool_timeout], node(agent_run, "alpha").values_at(:status, :error_key)
    assert_equal :task_not_claimable, claim(agent_run, "alpha").outcome
  end

  # The same race on a WRITE profile: the sweep's word is `uncertain`, and the claim after it is
  # refused the same way — the machine has one terminal shape whatever the word.
  test "sweep first on a claimed write call: the expiry is uncertain, and the claim after it is task_not_claimable" do
    agent_run = seed({ "tool" => { "key" => "job", "name" => "bash", "input" => { "command" => "x" },
      "route" => { "kind" => "runner" } } })
    start!(agent_run)
    assert_predicate claim(agent_run, "job"), :accepted?
    expire!(node(agent_run, "job"))

    assert_equal 1, sweep[:expired]
    assert_equal %w[uncertain tool_uncertain], node(agent_run, "job").values_at(:status, :error_key)
    assert_equal :task_not_claimable, claim(agent_run, "job").outcome
  end

  # (ii) Claim first on a NEVER-claimed expired row: the grant re-arms the
  # park's clock, so the sweep's re-derivation under the loop lock reads
  # the new deadline and answers `idle` — the node stays dispatched. The
  # property, not the colour: `timed_out: 0` AND `dispatched`.
  test "claim first on a never-claimed expired row: the grant re-arms the clock and the sweep lists nothing" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    expire!(node(agent_run, "alpha"))

    granted = claim(agent_run, "alpha")
    assert_predicate granted, :accepted?, "a row nobody ever claimed is claimable whatever its clock says"
    assert_operator node(agent_run, "alpha").await_started_at, :>, 1.minute.ago, "the clock restarted"

    result = sweep
    assert_equal 0, result[:expired], "the sweep's re-derivation read the re-armed deadline"
    assert_equal "dispatched", node(agent_run, "alpha").status
    assert_equal granted.value.claim_token, node(agent_run, "alpha").claim_token
  end

  # (iii) Claim first on an EVER-claimed expired row: refused `already_claimed` regardless of the
  # deadline, and the sweep settles it in its turn — no interleaving re-runs a claimed effect.
  test "claim first on an ever-claimed expired row: already_claimed, then the sweep settles it" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    first = claim(agent_run, "alpha")
    assert_predicate first, :accepted?
    expire!(node(agent_run, "alpha"))

    assert_equal :already_claimed, claim(agent_run, "alpha").outcome
    assert_equal first.value.claim_token, node(agent_run, "alpha").claim_token, "no rotation under a refusal"
    assert_equal 1, sweep[:expired]
    assert_equal "timed_out", node(agent_run, "alpha").status, "read_file is replayable: a plain timeout"
  end

  # An ask is an inbox row addressed to the agent application and is never claimed: one answerer by
  # construction, on a person's clock.
  test "an ask row is not_claimable_kind" do
    agent = users(:agent)
    agent_run = seed(model("round1", "tools" => [Nexus::Tools::ASK]), creating_user: agent)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: agent))
    row = ask_through_the_model!(agent_run)
    address = task_executors(:address)
    assert_equal "awaiting_input", row.status
    assert_equal address.id, row.addressed_executor_id, "the ask is addressed to the declaring agent's address"

    result = claim(agent_run, row.node_key, executor: address)
    assert_equal :not_claimable_kind, result.outcome
    assert_nil row.reload.claimed_at
    assert_equal :not_addressed_here, claim(agent_run, row.node_key).outcome,
      "another address is refused by the address before the kind is looked at"
  end

  # awaits_test's route to the kernel's tokenless ask: the model calls
  # `ask`, AskJob appends the await, the scheduler addresses it.
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
    agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole.reload
  end

  test "a needs_approval row is not_claimable_kind" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    row = node(agent_run, "alpha")
    AgentRunTask.where(id: row.id).update_all(status: "needs_approval")

    assert_equal :not_claimable_kind, claim(agent_run, "alpha").outcome
    assert_nil row.reload.claimed_at
  end

  # The same answer on a row the stage parked itself: the approval row is a notice, not work; its
  # end is the member verbs or the clock, never a claim — by its addressee or by the runner the call
  # would go to.
  test "a row parked under ask is not_claimable_kind for its addressee and for the runner" do
    agent = users(:agent)
    address = TaskExecutor.address_for(agent)
    read_tool = RunLaneTestHelper::READ_TOOL.merge("route" => {
      "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id, "tool_name" => "read_file",
    })
    agent_run = seed(model("round1", "tools" => [read_tool]),
      creating_user: agent, approval_mode: "ask")
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: agent))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    round = agent_run.agent_run_tasks.find_by!(node_key: "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("reading", tool_calls: [{ id: "call_r", name: "read_file", arguments: "{}" }]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_r")
    assert_equal "needs_approval", call.status

    assert_equal :not_claimable_kind, claim(agent_run, call.node_key, executor: address).outcome,
      "the addressee reads a notice, never work"
    assert_equal :not_addressed_here, claim(agent_run, call.node_key).outcome,
      "the runner is not the addressee until the release re-runs Address"
    assert_nil call.reload.claimed_at
  end

  # THE SCOPE STAMP ON THE CLAIM: the claim door renders the same row the inbox lists, so an
  # overridden row's `scope` rides both; the row is the provider's, and a runner claiming it is
  # `not_addressed_here`.
  test "an overridden row's claim returns the stamped row, and a runner is not addressed" do
    names = Nexus::ToolRegistry.wire_names_in("nexus.memory")
    provider = connect_provider(identifier: "mem", tools: names.map { |name|
      { "name" => name, "effect_profile" => Nexus::ToolRegistry.effect_profile_for(name) }
    })
    assert_equal :updated, Workspaces::SetToolProviderOverrides.call(
      workspace: @workspace, by: users(:owner), lock_version: @workspace.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    ).outcome
    agent_run = seed({ "model" => { "key" => "round1", "model" => MOCK_MODEL, "prompt" => "p",
                                     "tools" => names.map { |name| Nexus::ToolRegistry.function_definition(name) } } })
    start!(agent_run)
    round = node(agent_run, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("writing", tool_calls: [
      { id: "call_w", name: "memory_write", arguments: { path: "workspace/notes.md", content: "x" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_w")
    assert_equal "dispatched", call.status

    assert_equal :not_addressed_here, claim(agent_run, call.node_key).outcome
    granted = claim(agent_run, call.node_key, executor: provider)
    assert_predicate granted, :accepted?
    row = Executors::Inbox.row(granted.value.reload)
    assert_equal({ bindings: [
      { name: "workspace", scope: "workspace", access: "read_write", workspace_public_id: @workspace.public_id },
      { name: "user", scope: "user", access: "read_write", user_public_id: @human.public_id },
    ] }, row.fetch(:scope))
    assert_equal({ "path" => "workspace/notes.md", "content" => "x" }, row.fetch(:tool_input))
    assert row.fetch(:claimed)
  end

  # THE TWO WORDS OF THE GRANT: the executor is judged for the loop's ANSWERER — a runner private to
  # the answerer's steward claims a row on a Human's loop-backed loop — while the write standing
  # that keeps the loop writing is the SPEAKER's, the loop's creator.
  test "the claim judges the executor for the loop's answerer, and the standing of its speaker" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private")
      .executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent),
      default_runner_executor: owners_private)
    agent_run = create_answered_loop(tool("alpha"), conversation: answered, acting_user: @human)
    assert_equal owners_private.id, node(agent_run, "alpha").addressed_executor_id

    Workspace.where(id: @workspace.id).update_all(access_mode: "private")
    assert_equal :not_authorized, claim(agent_run.reload, "alpha", executor: owners_private).outcome,
      "the SPEAKER lost its write standing; the answerer's steward owns the room and keeps it"

    Workspace.where(id: @workspace.id).update_all(access_mode: "account_wide")
    assert_predicate claim(agent_run.reload, "alpha", executor: owners_private), :accepted?
  end

  # The turn's answerer: the same judgment on a Human's conversation whose one turn is addressed to
  # the agent.
  test "the claim judges the executor for the TURN's answerer" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private")
      .executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    plain = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: owners_private)
    agent_run = create_answered_loop(tool("alpha"), conversation: plain, acting_user: @human, answering_user: users(:agent))

    assert_equal owners_private.id, node(agent_run, "alpha").addressed_executor_id
    assert_predicate claim(agent_run, "alpha", executor: owners_private), :accepted?

    twin = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: owners_private)
    human_loop = create_run_backed_turn(conversation: twin, acting_user: @human).agent_run
    assert_equal @human, human_loop.answering_user
    assert_equal :runner_not_eligible, grow(human_loop, tool("beta")).outcome,
      "the Human-answered twin refuses its ineligible Runner at task acceptance"
    assert_empty human_loop.agent_run_tasks
  end
end
