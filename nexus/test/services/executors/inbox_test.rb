require "test_helper"

# The executor boundary's TWO CHANNELS, one truth: the HTTP inbox is level-triggered and complete (a
# runner that slept or crashed recovers by reading it), and the realtime nudge carries no work of
# its own — so a dropped push costs latency and never a task. The inbox is an EXECUTOR'S view of the
# rows addressed to it across every workspace: the address is the scope, and the claim is granted to
# the addressee, never on a caller's standing.
class Executors::InboxTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read_file", **over) = super(key, name, "input" => { "path" => key }, **over)

  # The executor streams only: the loop's own feeds narrate the park too.
  def executor_broadcasts
    broadcasts = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { broadcasts << [stream, payload] }) { yield }
    broadcasts.select { |stream, _payload| stream.start_with?("agent_api:v1:executor:") }
  end

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def inbox(executor: suite_runner, **over)
    Executors::Inbox.call(executor: executor, **over)
  end

  def claim(agent_loop, key, executor: suite_runner)
    Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: key, executor: executor
    ))
  end

  # A second announcer of the same vocabulary — two runners, one row.
  def second_runner
    @second_runner ||= connect_runner(
      manager: users(:owner), runner_identifier: "test-runner-2",
      display_name: "Second runner", assignment_scope: :account_wide
    ).executor_access_token.task_executor.tap do |runner|
      assert_predicate runner.announce(tools: TEST_SERVED_TOOLS), :accepted?
    end
  end

  # THE PARK'S BUDGET ON THE ROW: the number `deadline_at` is cut from — the step's authored
  # `timeout_ms`, else the kernel's default — so an executor names the budget it was held to
  # without reading a clock of its own.
  test "the row states the park's budget its deadline was cut from" do
    agent_loop = seed(parallel(tool("alpha", "timeout_ms" => 60_000), tool("beta")), tool("gamma"))
    start!(agent_loop)

    rows = inbox.tasks.index_by { |row| row.fetch(:task_key) }
    assert_equal 60_000, rows.fetch("alpha").fetch(:timeout_ms), "the authored budget"
    assert_equal AgentLoopNodes::ToolTask::DEFAULT_TIMEOUT_MS, rows.fetch("beta").fetch(:timeout_ms),
      "else the kernel's"
    rows.each do |key, row|
      node = agent_loop.agent_loop_nodes.find_by!(node_key: key)
      assert_in_delta row.fetch(:timeout_ms) / 1000.0, Time.iso8601(row.fetch(:deadline_at)) - node.await_started_at, 1,
        "#{key}: the deadline is the budget from the park's start, at the stamp's whole seconds"
    end
  end

  # ── the scope stamp: the kernel stating whose row this is ──

  MEMORY_NAMES = Nexus::ToolRegistry.wire_names_in("nexus.memory")

  def memory_provider
    connect_provider(identifier: "mem", tools: MEMORY_NAMES.map { |name|
      { "name" => name, "effect_profile" => Nexus::ToolRegistry.effect_profile_for(name) }
    })
  end

  def override!(provider, workspace: @workspace)
    result = Workspaces::SetToolProviderOverrides.call(
      workspace: workspace, by: users(:owner), lock_version: workspace.reload.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    )
    assert_equal :updated, result.outcome
  end

  def memory_model(key = "round1")
    { "model" => { "key" => key, "model" => MOCK_MODEL, "prompt" => "p",
                   "tools" => MEMORY_NAMES.map { |name| Nexus::ToolRegistry.function_definition(name) } } }
  end

  # A kernel name reaches the inbox ONLY through a model's call under an
  # override — the client append door refuses it — so the row is minted
  # through a round; the final schedule is the park, and it is what nudges.
  def memory_call_through_the_model!(agent_loop, acting_user:, name: "memory_read")
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: acting_user))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
    round = agent_loop.agent_loop_nodes.find_by!(node_key: "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("reading", tool_calls: [
      { id: "call_m", name: name, arguments: { path: "workspace/notes.md" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    broadcasts = executor_broadcasts { AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id) }
    [agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_m"), broadcasts]
  end

  test "an overridden row carries the kernel's scope stamp, and nothing else does" do
    provider = memory_provider
    override!(provider)
    agent_loop = seed(memory_model, creating_user: users(:agent))
    call, broadcasts = memory_call_through_the_model!(agent_loop, acting_user: users(:agent))
    assert_equal "dispatched", call.status

    stamp = { bindings: [
      { name: "workspace", scope: "workspace", access: "read_write", workspace_public_id: @workspace.public_id },
      { name: "user", scope: "user", access: "read_write", user_public_id: users(:owner).public_id },
    ] }
    row = inbox(executor: provider).tasks.sole
    assert_equal "memory_read", row.fetch(:tool_name)
    assert_equal({ "path" => "workspace/notes.md" }, row.fetch(:tool_input), "tool_input passes through untouched")
    assert_equal @workspace.public_id, row.fetch(:workspace_public_id)
    assert_equal stamp, row.fetch(:scope),
      "a standalone loop: no conversation, and user/ is the creating agent's STEWARD"
    assert_equal({ role: "tools_provider", executor_public_id: provider.public_id }, row.fetch(:addressed_to))

    stream, payload = broadcasts.sole
    assert_equal AgentAPI::V1::ExecutorInboxChannel.stream_name(provider.public_id), stream,
      "the nudge names the provider's channel"
    assert_equal "memory_read", payload.dig(:event, :tool_name)

    assert_equal [], inbox.tasks, "the bound runner never lists a kernel row"
    assert_equal :not_addressed_here, claim(agent_loop, call.node_key).outcome
    granted = claim(agent_loop, call.node_key, executor: provider)
    assert_predicate granted, :accepted?
    assert_equal stamp, Executors::Inbox.row(granted.value.reload).fetch(:scope), "the claim's row is the same object"
  end

  test "a loop-backed overridden row stamps its conversation" do
    provider = memory_provider
    override!(provider)
    memory_tools = MEMORY_NAMES.map { |name| Nexus::ToolRegistry.function_definition(name) }
    declare_tools!(users(:agent), tools: memory_tools)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: users(:agent), text: "read the notes")
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("reading", tool_calls: [
      { id: "call_m", name: "memory_read", arguments: { path: "workspace/notes.md" }.to_json },
    ]))

    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_m")
    assert_equal provider.id, call.addressed_executor_id
    stamp = { bindings: [
      { name: "conversation", scope: "conversation", access: "read_write", conversation_public_id: conversation.public_id },
      { name: "workspace", scope: "workspace", access: "read_write", workspace_public_id: @workspace.public_id },
      { name: "user", scope: "user", access: "read_write", user_public_id: users(:owner).public_id },
    ] }
    assert_equal stamp, Executors::Inbox.row(call).fetch(:scope)
    listed = inbox(executor: provider).tasks.sole
    assert_equal stamp, listed.fetch(:scope), "the listed row, through the preloads"
    # EVERY row names its conversation (the process lifecycle follows the
    # conversation, 2026-09-10): a runner owns what a call starts by it.
    assert_equal conversation.public_id, listed.fetch(:conversation_public_id)
    # A ROOT conversation has no parent: the explicit null, never an absent key.
    assert listed.key?(:parent_public_id)
    assert_nil listed.fetch(:parent_public_id), "a root conversation's row names no parent"
  end

  # THE PARENT ON THE ROW: a spawned child's row carries its PARENT conversation's public id — the
  # snapshot the kernel keeps on the child (`Conversation#parent_conversation_public_id`, the weak
  # reference that survives the parent's reap) — the same kind of fact as `conversation_public_id`
  # and `addressed_to`, no key of any argument interpreted. A runner elsewhere resolves the child's
  # environment by its parent's received binding with no relay in the path; the kernel says nothing
  # about environments and never reads the store.
  test "a spawned child's row names its parent conversation, and the claim's row is the same object" do
    provider = memory_provider
    override!(provider)
    memory_tools = MEMORY_NAMES.map { |name| Nexus::ToolRegistry.function_definition(name) }
    declare_tools!(users(:agent), tools: memory_tools)
    parent = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    child = Conversation.create!(workspace: @workspace, creating_user: users(:agent), answering_user: users(:agent),
      parent_conversation: parent, parent_conversation_public_id: parent.public_id)
    assert_predicate child, :subagent?
    _turn, agent_loop = materialize_loop_reply!(child, agent: users(:agent), text: "read the notes")
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("reading", tool_calls: [
      { id: "call_m", name: "memory_read", arguments: { path: "workspace/notes.md" }.to_json },
    ]))

    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_m")
    listed = inbox(executor: provider).tasks.sole
    assert_equal child.public_id, listed.fetch(:conversation_public_id), "the row is the child's"
    assert_equal @workspace.public_id, listed.fetch(:workspace_public_id)
    assert_equal parent.public_id, listed.fetch(:parent_public_id), "and it names the child's parent"
    assert_equal parent.public_id, Executors::Inbox.row(call).fetch(:parent_public_id), "the claim's row is the same object"
  end

  # ── the pool: listed for every eligible member until claimed ──

  POOLED = "net_fetch".freeze

  def pool_row(agent_loop) = agent_loop.agent_loop_nodes.find_by!(tool_name: POOLED)

  test "a pool row lists for every member until one claims it, then for the claimant alone" do
    first = connect_provider(identifier: "pool-a", tools: [POOLED])
    second = connect_provider(identifier: "pool-b", tools: [POOLED])
    agent_loop = seed(tool("fetch", POOLED))
    start!(agent_loop)

    [first, second].each do |member|
      row = inbox(executor: member).tasks.sole
      assert_equal "fetch", row.fetch(:task_key)
      assert_equal({ role: "tools_provider" }, row.fetch(:addressed_to), "no executor on a pool row")
      assert_equal false, row.fetch(:claimed)
    end
    assert_equal [], inbox.tasks, "the bound runner is not a member"

    granted = claim(agent_loop, "fetch", executor: first)
    assert_predicate granted, :accepted?
    assert_equal first.public_id, pool_row(agent_loop).claimed_by_executor_public_id
    assert_equal :already_claimed, claim(agent_loop, "fetch", executor: second).outcome,
      "the claim resolves the race as two runners racing one row do"

    assert inbox(executor: first).tasks.sole.fetch(:claimed), "the claimant sees the row it holds"
    assert_equal [], inbox(executor: second).tasks, "another member never sees a row it can no longer take"
  end

  test "a member not eligible for the loop's principal neither lists nor claims the pool row, and pages past it" do
    foreign = connect_provider(identifier: "owner-private", tools: [POOLED], assignment_scope: :user_private)
    member = connect_provider(identifier: "pool-wide", tools: [POOLED])
    agent_loop = seed(tool("fetch", POOLED))
    start!(agent_loop)
    stewarded = seed(tool("mine", POOLED), creating_user: users(:agent))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: stewarded, acting_user: users(:agent)))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: stewarded.id)
    clear_enqueued_jobs

    assert_equal %w[fetch mine], inbox(executor: member).tasks.map { |row| row[:task_key] }
    page = inbox(executor: foreign, limit: 1)
    assert_equal [], page.tasks, "the Human's row is filtered by eligibility"
    assert_not_nil page.next_after, "and the cursor still advances past it"
    assert_equal %w[mine], inbox(executor: foreign, after: AgentLoopNode::InboxCursor.decode(page.next_after))
      .tasks.map { |row| row[:task_key] }
    assert_equal :not_eligible, claim(agent_loop, "fetch", executor: foreign).outcome
  end

  test "a provider announcing another name is not a member and the bound runner's rows never list for it" do
    outsider = connect_provider(identifier: "other", tools: ["something_else"])
    agent_loop = seed(parallel(tool("alpha"), tool("fetch", POOLED)), tool("gamma"))
    start!(agent_loop)

    assert_equal [], inbox(executor: outsider).tasks
    assert_equal :not_addressed_here, claim(agent_loop, "fetch", executor: outsider).outcome
    assert_equal :not_addressed_here, claim(agent_loop, "alpha", executor: outsider).outcome
    assert_equal %w[alpha], inbox.tasks.map { |row| row[:task_key] }
  end

  # Under bypass the stage is crossed in the same transaction as the
  # dispatch, so the executor is nudged exactly once, for the `tool_call`.
  test "under bypass the crossing nudges the runner once, for the tool_call" do
    agent_loop = seed(tool("alpha"))
    broadcasts = executor_broadcasts { start!(agent_loop) }
    assert_equal 1, broadcasts.length, "one nudge for the crossing"
    assert_equal "tool_call", broadcasts.sole.last.dig(:event, :kind)
  end

  # THE APPROVAL ROW IS AN INBOX ROW: a model-composed call parked under `ask` LISTS on the
  # addressed agent application's inbox as kind `approval` with the call and the frozen effect
  # profile the approver reads, `claimed: false`, on the 24 h park clock — nudged once as
  # `approval`, never claimed (the verbs are member-plane). A Human's loop has no agent application:
  # its held row lists in no inbox and nudges nobody — the person's member door alone.
  test "an approval row lists on the agent application's inbox with the effect profile, nudges once and is never claimable" do
    agent = users(:agent)
    address = TaskExecutor.address_for(agent)
    create_bound_credential(executor: address, name: "Lane transport")
    agent_loop = seed(model("round1", "tools" => [Nexus::Tools::ASK, LoopLaneTestHelper::READ_TOOL]),
      creating_user: agent, approval_mode: "ask")
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: agent))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
    round = agent_loop.agent_loop_nodes.find_by!(node_key: "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("reading", tool_calls: [
      { id: "call_r", name: "read_file", arguments: { path: "notes.md" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    broadcasts = executor_broadcasts { AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id) }
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_r")
    assert_equal "needs_approval", call.status
    assert_equal "approval", call.inbox_kind

    stream, payload = broadcasts.sole
    assert_equal AgentAPI::V1::ExecutorInboxChannel.stream_name(address.public_id), stream,
      "the park nudges the agent application, once"
    assert_equal "approval", payload.dig(:event, :kind)
    assert_equal call.node_key, payload.dig(:event, :task_key)

    row = inbox(executor: address).tasks.sole
    assert_equal "approval", row.fetch(:kind)
    assert_equal @workspace.public_id, row.fetch(:workspace_public_id)
    assert_equal "read_file", row.fetch(:tool_name)
    assert_equal({ "path" => "notes.md" }, row.fetch(:tool_input))
    assert_equal call.effect_profile, row.fetch(:effect_profile), "what the approver reads: the profile frozen on the row"
    assert_equal false, row.fetch(:claimed)
    assert_equal({ role: "agent_application", executor_public_id: address.public_id }, row.fetch(:addressed_to))
    assert_in_delta call.await_started_at + AgentLoopNodes::AwaitTask::MAX_HOLD, Time.iso8601(row.fetch(:deadline_at)), 1
    refute row.key?(:started_at), "nothing was dispatched"
    assert_equal [], inbox.tasks, "the runner the call would be dispatched to sees nothing yet"

    assert_equal :not_claimable_kind, claim(agent_loop, call.node_key, executor: address).outcome,
      "the addressee reads a notice, never work"
    assert_equal :not_addressed_here, claim(agent_loop, call.node_key).outcome, "the runner's turn comes at the release"
    assert_nil call.reload.claimed_at
  end

  # An aliased call resting for an approver: the row names the kernel's tool and, beside it, the
  # spelling the model used.
  test "an approval row carries the alias the model used beside the kernel's tool name" do
    agent = users(:agent)
    address = TaskExecutor.address_for(agent)
    create_bound_credential(executor: address, name: "Lane transport")
    agent_loop = seed(model("round1", "tools" => [LoopLaneTestHelper::AGENT_ALIAS, LoopLaneTestHelper::READ_TOOL]),
      creating_user: agent, approval_mode: "ask")
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: agent))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
    round = agent_loop.agent_loop_nodes.find_by!(node_key: "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("delegating", tool_calls: [
      { id: "call_a", name: "Agent", arguments: { prompt: "review", run_in_background: false }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a")
    assert_equal "needs_approval", call.status

    row = inbox(executor: address).tasks.sole
    assert_equal %w[approval task Agent], row.values_at(:kind, :tool_name, :tool_alias)
    assert_equal({ "prompt" => "review", "wait" => true }, row.fetch(:tool_input), "the approver reads the kernel's words")
  end

  test "a Human's standalone loop's held row lists in no inbox and nudges nobody" do
    agent_loop = seed(model("round1", "tools" => [LoopLaneTestHelper::READ_TOOL]), approval_mode: "ask")
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
    round = agent_loop.agent_loop_nodes.find_by!(node_key: "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("reading", tool_calls: [
      { id: "call_r", name: "read_file", arguments: "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    broadcasts = executor_broadcasts { AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id) }

    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_r")
    assert_equal "needs_approval", call.status
    assert_nil call.addressed_executor_id
    assert_nil call.addressed_role
    assert_equal [], broadcasts, "nobody to nudge"
    assert_equal [], inbox.tasks
    assert_equal [], inbox(executor: task_executors(:address)).tasks
  end

  test "a row addressed to another executor is neither listed nor claimable there" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    address = task_executors(:address)

    assert_equal [], inbox(executor: address).tasks, "the agent address sees none of the runner's rows"
    assert_equal :not_addressed_here, claim(agent_loop, "alpha", executor: address).outcome
  end

  # The workspace is not a scope on the executor plane: one credential, one inbox, every live loop
  # that addressed it.
  test "the inbox spans workspaces: one executor, two workspaces, both rows listed in id order" do
    first = seed(tool("alpha"))
    start!(first)
    second_workspace = Workspace.create!(
      account: @account, creator: users(:owner), owner: users(:owner),
      name: "Second", access_mode: "account_wide"
    )
    second = seed(tool("beta"), workspace: second_workspace)
    start!(second)

    rows = inbox.tasks
    assert_equal %w[alpha beta], rows.map { |row| row[:task_key] }
    assert_equal [first.public_id, second.public_id], rows.map { |row| row[:agent_loop_public_id] }
  end

  test "answered work leaves the inbox; the inbox is the state, not a queue" do
    agent_loop = seed(parallel(tool("alpha"), tool("beta")), tool("gamma"))
    start!(agent_loop)

    AgentLoops::Parks::Settle.call(
      node: agent_loop.agent_loop_nodes.find_by!(node_key: "alpha"),
      trusted: true, content: "done", outcome: "completed"
    )
    assert_equal %w[beta], inbox.tasks.map { |t| t[:task_key] },
      "a runner re-reading after a crash sees exactly what is still owed"
  end

  test "a graceful stop keeps its parks answerable — the drain waits on exactly those" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    assert_equal 1, inbox.tasks.length

    AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
      agent_loop: agent_loop, acting_user: @human, force: false
    ))
    assert_equal %w[alpha], inbox.tasks.map { |t| t[:task_key] },
      "hiding it left the runner unable to answer the very work the drain " \
        "was waiting on, so the stop ran to its hard limit instead of " \
        "ending in seconds (slice review)"

    AgentLoops::Parks::Settle.call(
      node: agent_loop.agent_loop_nodes.find_by!(node_key: "alpha"),
      trusted: true, content: "done", outcome: "completed"
    )
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    assert_equal "canceled", agent_loop.reload.status
    assert_equal [], inbox.tasks
  end

  test "a forced stop takes the parks off the inbox by cancelling them" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    AgentLoops::Stop.call(AgentLoops::Stop::Command.forced(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_equal [], inbox.tasks, "stop means stop: nothing left to answer"
  end

  test "single delivery: one claim wins, the other is refused, and the token gates the answer" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha")

    first = claim(agent_loop, "alpha")
    assert_predicate first, :accepted?
    assert first.value.claim_token.present?
    assert_equal suite_runner.id, node.reload.claimed_by_executor_id
    assert_equal suite_runner.public_id, node.claimed_by_executor_public_id

    second = claim(agent_loop, "alpha")
    assert_equal :already_claimed, second.outcome,
      "the inbox is complete by design, so two processes of one address SEE " \
        "the same row - the claim is where exactly one of them wins"
    assert_equal :not_addressed_here, claim(agent_loop, "alpha", executor: second_runner).outcome,
      "another address is refused before the claim is even looked at"

    assert_equal :stale_claim, AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: "not-the-token", content: "x", outcome: "completed"
    ).outcome, "and the token gates the answer, so a second executor's " \
      "result cannot land over the holder's"
    assert_predicate AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: first.value.claim_token, content: "done",
      outcome: "completed"
    ), :applied?
  end

  # Expiry is the sweep's alone: a row ever claimed in this generation is refused whether or not its
  # deadline passed, so a crashed holder's `bash` can never be blindly re-run by a second taker
  # inside the sweep's window. The holder's own token settles until the deadline.
  test "a lapsed claim is refused, and the sweep settles it" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha")

    first = claim(agent_loop, "alpha")
    assert_predicate first, :accepted?
    assert inbox.tasks.sole.fetch(:claimed), "held work is marked, so a runner skips it"

    AgentLoopNode.where(id: node.id).update_all(await_started_at: 2.hours.ago)
    assert inbox.tasks.sole.fetch(:claimed), "a lapsed claim is still a claim: never re-granted"
    assert_equal :already_claimed, claim(agent_loop, "alpha").outcome,
      "a second taker inside the sweep's window would be a blind double-run"
    assert_equal first.value.claim_token, node.reload.claim_token, "the token does not rotate under a refusal"

    assert_equal :stale_claim, AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: "not-the-token", content: "x", outcome: "completed"
    ).outcome
    late = AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: first.value.claim_token, content: "late", outcome: "completed"
    )
    assert_predicate late, :applied?
    assert_equal "timed_out", node.reload.status,
      "past the deadline the clock wins, as it always did — and read_file is replayable, so a plain timeout"
  end

  test "a lapsed WRITE claim's late answer is not trusted either: the sweep's word is uncertain" do
    agent_loop = seed(tool("alpha", "bash"))
    start!(agent_loop)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha")
    first = claim(agent_loop, "alpha")
    assert_predicate first, :accepted?
    AgentLoopNode.where(id: node.id).update_all(await_started_at: 2.hours.ago)

    late = AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: first.value.claim_token, content: "late", outcome: "completed"
    )
    assert_predicate late, :applied?
    assert_equal %w[uncertain tool_uncertain], node.reload.values_at(:status, :error_key),
      "a claimed write past its deadline may have happened: no late truth, no blind replay"
  end

  test "the holder's own token settles while the deadline stands" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha")

    first = claim(agent_loop, "alpha")
    assert_equal :already_claimed, claim(agent_loop, "alpha").outcome
    assert_predicate AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: first.value.claim_token, content: "done", outcome: "completed"
    ), :applied?, "the holder's own result is not thrown away"
  end

  test "exclusivity is by TOKEN, never by the caller's standing: one address, one row" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)

    first = claim(agent_loop, "alpha")
    assert_predicate first, :accepted?
    assert_equal :already_claimed, claim(agent_loop, "alpha").outcome,
      "a runner FLEET sharing one service identity is the documented " \
        "deployment - exempting the same address handed two of its " \
        "processes the same task (slice review)"
    assert_equal :not_addressed_here, claim(agent_loop, "alpha", executor: second_runner).outcome,
      "and a different address was never asked: the row names its addressee"
  end

  test "the claim reads the loop's frozen principal and the executor's eligibility, at the grant" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)

    suite_runner.revoke
    assert_equal :not_eligible, claim(agent_loop, "alpha").outcome,
      "the addressee lost its standing since the row was addressed"
  end

  test "a retried tool park sheds its dead claim and its stale display material" do
    agent_loop = seed(tool("alpha", "on_failure" => "propagate"))
    start!(agent_loop)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha")

    claimed = claim(agent_loop, "alpha")
    AgentLoops::Parks::Settle.call(
      node: node.reload, claim_token: claimed.value.claim_token,
      content: "the first answer", outcome: "failed"
    )
    assert_equal "the first answer", node.reload.output_preview
    assert_equal suite_runner.id, node.addressed_executor_id
    assert_equal suite_runner.id, node.claimed_by_executor_id

    AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "alpha", acting_user: @human
    ))
    node.reload
    assert_nil node.output_preview,
      "the transcript reads the COLUMN, so a stale stamp would render the " \
        "previous run's answer as the new attempt's result"
    assert_nil node.claim_token, "and a dead runner's token must not settle it"
    assert_nil node.claimed_at
    assert_nil node.claimed_by_executor_id
    assert_nil node.claimed_by_executor_public_id
    # The next start re-addresses the generation.
    assert_nil node.addressed_executor_id
    assert_nil node.addressed_role
    assert_nil node.effect_profile
  end

  test "the runner's UI channel is bounded and storable like every other payload" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha")
    claimed = claim(agent_loop, "alpha")

    settle = lambda do |**over|
      AgentLoops::Parks::Settle.call(
        node: node.reload, claim_token: claimed.value.claim_token, content: "ok",
        outcome: "completed", **over
      )
    end

    assert_equal :invalid_title, settle.call(title: "bad\u0000title").outcome,
      "a NUL reached Postgres at INSERT and aborted the settle as a 500"
    assert_equal :invalid_metadata, settle.call(metadata: "not an object").outcome
    huge = { "blob" => "x" * (Nexus::SizeBounds.fetch(:envelope_bound) + 1) }
    assert_equal :metadata_too_large, settle.call(metadata: huge).outcome,
      "an unbounded jsonb escapes the documented payload boundary and " \
        "uncaps the transcript page it renders into"

    assert_predicate settle.call(title: "read a.rb", metadata: { "lines" => 12 }),
      :applied?
    assert_equal "read a.rb", node.reload.result_title
    assert_equal({ "lines" => 12 }, node.result_metadata)
  end

  test "a paused loop hands out nothing — its clocks are frozen" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: agent_loop, acting_user: @human
    ))
    assert_equal [], inbox.tasks
  end

  test "the page is bounded and its cursor is opaque" do
    agent_loop = seed(parallel(*(1..3).map { |n| tool("t#{n}") }), tool("t4"))
    start!(agent_loop)

    page = inbox(limit: 2)
    assert_equal %w[t1 t2], page.tasks.map { |t| t[:task_key] }
    assert_not_nil page.next_after
    assert_no_match(/\A\d+\z/, page.next_after, "the cursor never renders an id")

    rest = inbox(limit: 2, after: AgentLoopNode::InboxCursor.decode(page.next_after))
    assert_equal %w[t3], rest.tasks.map { |t| t[:task_key] }
    assert_nil rest.next_after

    assert_raises(AgentLoopNode::InboxCursor::MalformedCursor) do
      AgentLoopNode::InboxCursor.decode("not-a-cursor")
    end
  end

  test "parking nudges the EXECUTOR's channel, naming the task but carrying no work" do
    agent_loop = seed(tool("alpha"))
    stream, payload = executor_broadcasts { start!(agent_loop) }.sole
    assert_equal AgentAPI::V1::ExecutorInboxChannel.stream_name(suite_runner.public_id), stream,
      "the stream is the addressee's, keyed by executor — never a workspace's"

    # IT NAMES WHERE AND WHICH — never WHAT. A kind, a task key and a tool
    # name let an executor claim that one task directly instead of paging
    # its inbox to find the new row. Neither is executable: the arguments
    # live only behind the inbox and the claim, so a lost push still
    # costs milliseconds and never a task.
    event = payload.fetch(:event)
    assert_equal({ type: Executors::Nudge::WORK_AVAILABLE, kind: "tool_call",
                   agent_loop_public_id: agent_loop.public_id,
                   task_key: "alpha", tool_name: "read_file" }, event)
    assert_empty event.keys.map(&:to_s) & %w[tool_input tool_call_id claim_token],
      "the cable never carries what the runner would EXECUTE"
  end

  # A model's ask on an agent-created loop is the agent application's inbox row: parking it nudges
  # the agent's channel with the kind and the task — no tool, and never the question itself.
  test "an addressed ask nudges the agent's channel with kind ask and no tool" do
    agent = users(:agent)
    address = TaskExecutor.address_for(agent)
    agent_loop = seed(model("round1", "tools" => [Nexus::Tools::ASK]), creating_user: agent)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: agent))
    broadcasts = executor_broadcasts { ask_through_the_model!(agent_loop) }

    asked = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::AwaitTask.sti_name).sole
    assert_equal "awaiting_input", asked.status
    stream, payload = broadcasts.sole
    assert_equal AgentAPI::V1::ExecutorInboxChannel.stream_name(address.public_id), stream
    assert_equal({ type: Executors::Nudge::WORK_AVAILABLE, kind: "ask",
                   agent_loop_public_id: agent_loop.public_id, task_key: asked.node_key },
      payload.fetch(:event))
    assert_equal [asked.node_key], inbox(executor: address).tasks.map { |row| row.fetch(:task_key) }
  end

  def ask_through_the_model!(agent_loop)
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
    round = agent_loop.agent_loop_nodes.find_by!(node_key: "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("asking", tool_calls: [
      { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
  end

  # A kernel-executed tool carries no addressee: nobody is nudged because nobody outside the kernel
  # is asked. The model's `ask` is the kernel tool the scheduler starts `running` in its own job.
  test "a kernel row publishes no nudge" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    broadcasts = executor_broadcasts do
      clear_enqueued_jobs
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
      round = agent_loop.agent_loop_nodes.find_by!(node_key: "round1")
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == round.selected_model_invocation_id
      end
      apply_via(admitted.attempt, sse_success("asking", tool_calls: [
        { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
      ]))
      AgentLoops::ConvergeTerminalSteps.call
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    call = agent_loop.agent_loop_nodes.find_by!(node_key: "r1t0")
    assert_equal "running", call.status
    assert_nil call.addressed_executor_id
    assert_nil call.inbox_kind
    assert_equal [], broadcasts
    assert_equal [], inbox.tasks
  end

  # A runner that claimed a task and a runner that listed one must be
  # looking at the same object. The claim answered with the TRACE
  # projection — what the task IS, not what to RUN — so every claim had
  # to be preceded by paging the inbox for the arguments.
  test "a granted claim answers with the executable row, so claiming is the fetch" do
    agent_loop = seed(tool("alpha"))
    start!(agent_loop)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: "alpha")

    row = Executors::Inbox.row(node.reload)
    listed = inbox.tasks.sole
    assert_equal listed, row, "one projection, both doors"
    assert_equal node.tool_input, row[:tool_input]
    assert_equal "alpha", row[:task_key]
  end

  test "a nudge that cannot publish never fails the park" do
    ActionCable.server.stub(:broadcast, ->(*) { raise "cable down" }) do
      agent_loop = seed(tool("alpha"))
      start!(agent_loop)
      assert_equal "dispatched",
        agent_loop.agent_loop_nodes.find_by!(node_key: "alpha").status,
        "the cable is latency sugar; the durable park is the truth"
    end
    assert_equal 1, inbox.tasks.length
  end

  # THE PRINCIPAL IS THE ANSWERER: a pool row on a loop-backed loop a Human authored lists for, and
  # is claimed by, a provider private to the steward of the agent the conversation is ANSWERED by.
  test "a pool row is listed and claimed for the loop's ANSWERER, never its speaker" do
    private_member = connect_provider(identifier: "owner-private", tools: [POOLED], assignment_scope: :user_private)
    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    agent_loop = create_answered_loop(tool("fetch", POOLED), conversation: answered, acting_user: @human)

    assert_equal %w[fetch], inbox(executor: private_member).tasks.map { |row| row[:task_key] },
      "the owner's private provider serves the agent the owner stewards"
    assert_predicate claim(agent_loop, "fetch", executor: private_member), :accepted?
  end

  # THE TURN'S ANSWERER: the loop derives its answerer from its turn, so a turn addressed to the
  # agent on a Human's plain conversation lists for the members eligible for the AGENT — the
  # conversation's default never enters the judgment.
  test "a pool row lists and claims for the TURN's answerer, on a conversation the Human answers by default" do
    private_member = connect_provider(identifier: "owner-private", tools: [POOLED], assignment_scope: :user_private)
    plain = Conversation.create!(workspace: @workspace, creating_user: @human)
    agent_loop = create_answered_loop(tool("fetch", POOLED), conversation: plain, acting_user: @human,
      answering_user: users(:agent))

    assert_equal @human, plain.answering_user
    assert_equal %w[fetch], inbox(executor: private_member).tasks.map { |row| row[:task_key] },
      "the owner's private provider serves the agent the owner stewards — the turn's answerer"
    assert_predicate claim(agent_loop, "fetch", executor: private_member), :accepted?
  end
end
