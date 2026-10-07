require "test_helper"

# Task acceptance freezes explicit Runner targets. Dispatch resolves their
# current served capability, the frozen skill source, kernel execution, the
# Agent address or a provider pool; inbox and claim read the addressed row.
class AgentRuns::AddressingTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  UNSERVED = "nobody_serves_this".freeze
  AGENT_ONLY = "agent_only_tool".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read_file", **over) = super(key, name, **over)

  def model(key, **over)
    super(key, "tools" => [Nexus::ToolRegistry.function_definition("wait"), Nexus::Tools::ASK, declared(UNSERVED)], **over)
  end

  def declared(name)
    { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
  end

  def start!(agent_run, acting_user: @human)
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

  # A round that calls `name` once, expanded and scheduled: the fan member
  # starts — addressed or failed — and the continuation waits on it.
  def fan!(agent_run, name, key: "round1")
    apply_via(step_attempt(agent_run, key), sse_success("calling", tool_calls: [
      { id: "call_#{name}", name: name, arguments: "{}" },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    agent_run.agent_run_tasks.find_by!(tool_call_id: "call_#{name}")
  end

  # The model's flat `ask` — the tokenless await the kernel's job appends.
  def ask!(agent_run, key: "round1")
    apply_via(step_attempt(agent_run, key), sse_success("asking", tool_calls: [
      { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole
  end

  def agent_address = TaskExecutor.address_for(@agent)

  # The agent's own address announcing `names`, credential-ready.
  def announce_on_address!(*names) = announce_tools!(@agent, names)

  test "a kernel name runs in-process with the registry's profile frozen and no addressee" do
    agent_run = seed(model("round1", "prompt" => "go"))
    start!(agent_run)
    call = fan!(agent_run, "wait")

    assert_equal "running", call.status
    assert_nil call.addressed_executor_id
    assert_nil call.addressed_role
    assert_equal Nexus::ToolRegistry::GRAPH_WRITE, call.effect_profile
  end

  test "an accepted Runner target dispatches its served name with the announcement frozen" do
    runner = suite_runner
    runner.announce(tools: [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                              "timeout_ms" => 45_000 }])
    agent_run = seed(tool("t"))
    assert_equal runner.id, agent_run.default_runner_executor_id, "the runner the seed named is the initial default"
    start!(agent_run)

    call = node(agent_run, "t")
    assert_equal "dispatched", call.status
    assert_equal runner.id, call.addressed_executor_id
    assert_equal "runner", call.addressed_role
    assert_equal runner.effect_profile_for("read_file"), call.effect_profile
    assert_equal 45_000, call.effect_profile.fetch("timeout_ms"), "the announced timeout rides the frozen profile"
    assert_equal 45_000, call.effective_timeout_ms, "and is the deadline's second source"
  end

  test "a name only the agent address announces is dispatched to the agent application" do
    agent_run = seed(tool("t", AGENT_ONLY), creating_user: @agent)
    assert_equal suite_runner.id, agent_run.default_runner_executor_id, "the seed named the default Runner separately from the Agent address"
    announce_on_address!(AGENT_ONLY)
    start!(agent_run, acting_user: @agent)

    call = node(agent_run, "t")
    assert_equal "dispatched", call.status
    assert_equal agent_address.id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role
    assert_equal agent_address.effect_profile_for(AGENT_ONLY), call.effect_profile
  end

  # An Agent announcement provides its own names; it does not select the
  # separate Runner default on a standalone Run.
  test "an agent address that announced before create does not become the Runner default" do
    announce_on_address!(AGENT_ONLY)
    agent_run = seed(tool("t", AGENT_ONLY), creating_user: @agent)
    assert_equal suite_runner.id, agent_run.default_runner_executor_id,
      "the named runner-kind row remains the default"
    start!(agent_run, acting_user: @agent)

    call = node(agent_run, "t")
    assert_equal "dispatched", call.status
    assert_equal agent_address.id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role
  end

  # The accepted Runner route owns the call even when an Agent serves the same name.
  test "an explicit Runner target wins over the agent address for a name both announce" do
    agent_run = seed(tool("t"), creating_user: @agent)
    announce_on_address!("read_file")
    assert_equal suite_runner.id, agent_run.default_runner_executor_id
    start!(agent_run, acting_user: @agent)

    call = node(agent_run, "t")
    assert_equal suite_runner.id, call.addressed_executor_id
    assert_equal "runner", call.addressed_role
  end

  # ── arm 4, the pool ──

  POOLED = "net_fetch".freeze

  # Two members, two profiles: the row freezes ONE document — the strictest
  # announced (replayable only if every member's entry is), with the
  # shortest announced park — so the sweep adjudicates a pool row by the
  # same one-document rule as every other row.
  test "a name only eligible providers announce is a pool row with the strictest profile frozen" do
    connect_provider(identifier: "pool-a", tools: [
      { "name" => POOLED, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED, "timeout_ms" => 60_000 },
    ])
    connect_provider(identifier: "pool-b", tools: [
      { "name" => POOLED, "effect_profile" => WRITE_PROFILE, "timeout_ms" => 30_000 },
    ])
    agent_run = seed(tool("t", POOLED))
    assert_equal suite_runner.id, agent_run.default_runner_executor_id, "a provider is never the binding"
    start!(agent_run)

    call = node(agent_run, "t")
    assert_equal "dispatched", call.status
    assert_nil call.addressed_executor_id, "a pool row names no executor"
    assert_equal "tool_provider", call.addressed_role
    assert_equal WRITE_PROFILE.merge("timeout_ms" => 30_000), call.effect_profile
    assert_not_predicate call, :replayable?
    assert_equal 30_000, call.effective_timeout_ms
  end

  test "two members with one replayable profile collapse to it" do
    entry = { "name" => POOLED, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED, "timeout_ms" => 45_000 }
    connect_provider(identifier: "pool-a", tools: [entry])
    connect_provider(identifier: "pool-b", tools: [entry.merge("timeout_ms" => 90_000)])
    agent_run = seed(tool("t", POOLED))
    start!(agent_run)

    call = node(agent_run, "t")
    assert_equal Nexus::ToolRegistry::READ_ONLY_CLOSED.merge("timeout_ms" => 45_000), call.effect_profile
    assert_predicate call, :replayable?
  end

  # Membership is the machine eligibility rule: a `user_private` provider serves its manager's
  # principals only.
  test "a user_private provider under a foreign manager is not a member: a Human loop's call is tool_not_served" do
    connect_provider(identifier: "owner-private", tools: [POOLED], assignment_scope: :user_private)

    human_loop = seed(tool("t", POOLED))
    start!(human_loop)
    assert_equal "tool_not_served", node(human_loop, "t").error_key

    stewarded = seed(tool("t", POOLED), creating_user: @agent)
    start!(stewarded, acting_user: @agent)
    assert_equal "tool_provider", node(stewarded, "t").addressed_role,
      "the agent the manager stewards is served"
  end

  # A pool cannot take a call accepted for a Runner or the Agent's own address.
  test "a Runner target and the agent address win over a provider for a name both announce" do
    connect_provider(identifier: "pool-a", tools: ["read_file", AGENT_ONLY])

    on_runner = seed(tool("t"))
    start!(on_runner)
    assert_equal suite_runner.id, node(on_runner, "t").addressed_executor_id
    assert_equal "runner", node(on_runner, "t").addressed_role

    on_agent = seed(tool("t", AGENT_ONLY), creating_user: @agent)
    announce_on_address!(AGENT_ONLY)
    start!(on_agent, acting_user: @agent)
    assert_equal agent_address.id, node(on_agent, "t").addressed_executor_id
    assert_equal "agent_application", node(on_agent, "t").addressed_role
  end

  test "a name nobody announces fails at start with tool_not_served, and the model reads it" do
    agent_run = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"))
    start!(agent_run)
    call = fan!(agent_run, UNSERVED)

    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_equal "no executor announces #{UNSERVED} for this principal", call.error_detail
    assert_equal "absorb", call.on_failure, "a fan member absorbs by default"
    assert_nil call.failure_resolution
    assert_equal :resolved, AgentRuns::Graph.settlement_of(call)
    assert_nil call.addressed_executor_id
    assert_nil call.deadline_at, "it never parked"

    continuation = node(agent_run, "r1")
    assert_equal "running", continuation.status, "the continuation is released, not stranded"
    build(step_attempt(agent_run, continuation.node_key))
    result = round_request_entries(continuation).find { |payload| payload["type"] == "tool_result_item" }
    assert_equal "<tool_use_error>The tool call could not run. (tool_not_served) " \
                 "no executor announces #{UNSERVED} for this principal</tool_use_error>",
      result.dig("payload", "output")
  end

  test "a client-authored task with propagate skips its successors instead" do
    agent_run = seed(tool("t", UNSERVED, "on_failure" => "propagate"), model("after", "prompt" => "then"))
    start!(agent_run)

    assert_equal "failed", node(agent_run, "t").status
    assert_equal "tool_not_served", node(agent_run, "t").error_key
    assert_equal "skipped", node(agent_run, "after").status
  end

  test "an ineligible Runner is refused at acceptance" do
    bare = @account.task_executors.create!(executor_kind: :runner, display_name: "Bare",
      registration_identifier: "bare", manager: users(:owner), assignment_scope: :account_wide)
    foreign = connect_runner(manager: users(:owner), registration_identifier: "owner-private",
      assignment_scope: :user_private).executor_access_token.task_executor
    [bare, foreign].each { |runner| assert_predicate runner.announce(tools: TEST_SERVED_TOOLS), :accepted? }
    revoked = suite_runner
    revoked.revoke
    [bare, foreign, revoked].each do |runner|
      result = create_loop(tool("t", "read_file", "route" => {
        "kind" => "runner", "runner_executor_public_id" => runner.public_id,
      }), default_runner_executor_public_id: nil)
      assert_equal :runner_not_eligible, result.outcome
    end
  end

  test "clearing the default does not change an accepted Runner target" do
    agent_run = seed(tool("t"))
    agent_run.update!(default_runner_executor: nil)
    start!(agent_run)
    assert_equal suite_runner.id, node(agent_run, "t").addressed_executor_id
  end

  # The addressee is frozen per execution generation: a re-announcement after dispatch retargets
  # nothing already handed out.
  test "the addressee stands across a re-announcement" do
    agent_run = seed(tool("t"))
    start!(agent_run)
    call = node(agent_run, "t")
    frozen = call.effect_profile

    assert_predicate suite_runner.announce(tools: []), :accepted?
    schedule!(agent_run)
    call.reload
    assert_equal suite_runner.id, call.addressed_executor_id
    assert_equal frozen, call.effect_profile
    assert_equal "dispatched", call.status
  end

  test "a retry retains the accepted target for its next generation" do
    first = suite_runner
    agent_run = seed(tool("t", "on_failure" => "propagate"))
    start!(agent_run)
    assert_equal first.id, node(agent_run, "t").addressed_executor_id
    AgentRuns::Parks::Settle.call(node: node(agent_run, "t"), trusted: true, content: "boom", outcome: "failed")

    second = connect_runner(manager: users(:owner), registration_identifier: "test-runner-2",
      assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate second.announce(tools: TEST_SERVED_TOOLS), :accepted?
    # Change only the host default to prove retry retains the task's accepted target.
    agent_run.update!(default_runner_executor: second)

    first_grant = node(agent_run, "t").approval_decided_at
    assert_not_nil first_grant
    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "t", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    requeued = node(agent_run, "t")
    assert_nil requeued.approval_origin, "the grant was the first generation's: the next crosses the stage anew"
    assert_nil requeued.approval_decided_at
    schedule!(agent_run)

    call = node(agent_run, "t")
    assert_equal "dispatched", call.status
    assert_equal first.id, call.addressed_executor_id
    assert_equal 1, call.execution_generation
    assert_equal "author", call.approval_origin
    assert_operator call.approval_decided_at, :>=, first_grant, "decided again, for this generation"
  end

  test "a tokened await is dispatched to nobody; a tokenless ask is addressed to the agent address or nil" do
    authored = seed(ask("gate"))
    start!(authored)
    gate = node(authored, "gate")
    assert_equal "dispatched", gate.status
    assert_not_nil gate.resolution_token
    assert_nil gate.addressed_executor_id
    assert_nil gate.addressed_role

    on_agent = seed(model("round1", "prompt" => "go"), creating_user: @agent)
    announce_on_address!("read_file")
    start!(on_agent, acting_user: @agent)
    asked = ask!(on_agent)
    assert_equal "awaiting_input", asked.status
    assert_nil asked.resolution_token
    assert_equal agent_address.id, asked.addressed_executor_id
    assert_equal "agent_application", asked.addressed_role

    on_human = seed(model("round1", "prompt" => "go"))
    start!(on_human)
    asked = ask!(on_human)
    assert_equal "awaiting_input", asked.status
    assert_nil asked.addressed_executor_id, "no agent declares a Human's standalone loop: the person's door only"
    assert_nil asked.addressed_role
  end

  # ── the override branch: the ONLY way a kernel name leaves the kernel ──

  MEMORY_NAMES = Nexus::ToolRegistry.wire_names_in("nexus.memory")

  # A round offering the kernel's own memory tools (and `wait`), so the
  # declared-only gate admits the call and the branch is what decides it.
  def memory_model(key)
    { "model" => { "key" => key, "model" => MOCK_MODEL, "prompt" => "p",
                   "tools" => [Nexus::ToolRegistry.function_definition("wait"),
                               *MEMORY_NAMES.map { |name| Nexus::ToolRegistry.function_definition(name) }] } }
  end

  def memory_entries(names = MEMORY_NAMES)
    names.map do |name|
      { "name" => name, "effect_profile" => Nexus::ToolRegistry.effect_profile_for(name), "timeout_ms" => 20_000 }
    end
  end

  def memory_provider(identifier: "mem", names: MEMORY_NAMES, **over)
    connect_provider(identifier: identifier, tools: memory_entries(names), **over)
  end

  def override!(provider, workspace: @workspace, by: users(:owner))
    result = Workspaces::SetToolProviderOverrides.call(
      workspace: workspace, by: by, lock_version: workspace.reload.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    )
    assert_equal :updated, result.outcome
  end

  def memory_call!(agent_run, name, key: "round1", path: "workspace/notes.md")
    apply_via(step_attempt(agent_run, key), sse_success("calling", tool_calls: [
      { id: "call_#{name}", name: name, arguments: { path: path }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    agent_run.agent_run_tasks.find_by!(tool_call_id: "call_#{name}")
  end

  test "an overridden namespace is addressed to the named provider with its announced profile frozen" do
    provider = memory_provider
    override!(provider)
    agent_run = seed(memory_model("round1"))
    start!(agent_run)

    call = memory_call!(agent_run, "memory_read")
    assert_equal "dispatched", call.status
    assert_equal provider.id, call.addressed_executor_id
    assert_equal "tool_provider", call.addressed_role
    assert_equal provider.effect_profile_for("memory_read"), call.effect_profile
    assert_equal 20_000, call.effect_profile.fetch("timeout_ms"), "the ANNOUNCED profile, not the registry's"
    assert_equal 20_000, call.effective_timeout_ms
  end

  # Kernel names never pool: a provider announcing the six names WITHOUT an
  # override changes nothing — the branch reads the workspace fact, never
  # the announcement, and `kernel?` is read before the runner, the address
  # and the pool.
  test "the override is the only way a kernel name leaves the kernel: an announcing provider alone changes nothing" do
    memory_provider
    agent_run = seed(memory_model("round1"))
    start!(agent_run)

    call = memory_call!(agent_run, "memory_read")
    assert_equal "running", call.status
    assert_nil call.addressed_executor_id
    assert_nil call.addressed_role
    assert_equal Nexus::ToolRegistry::MEMORY_READ, call.effect_profile
  end

  # The announcement is accepted but does not activate an override: the opt-in names a tools
  # provider, and a runner is never one.
  test "a runner announcing memory_read is never addressed for it" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + memory_entries(["memory_read"])), :accepted?

    plain = seed(memory_model("round1"))
    start!(plain)
    call = memory_call!(plain, "memory_read")
    assert_equal "running", call.status
    assert_nil call.addressed_executor_id

    provider = memory_provider
    override!(provider)
    overridden = seed(memory_model("round1"))
    start!(overridden)
    call = memory_call!(overridden, "memory_read")
    assert_equal provider.id, call.addressed_executor_id, "the provider, not the runner that announced it"
  end

  test "no fallback: a revoked provider fails the call tool_not_served, naming it" do
    provider = memory_provider
    override!(provider)
    provider.revoke
    agent_run = seed(memory_model("round1"), model("m2", "prompt" => "then"))
    start!(agent_run)

    call = memory_call!(agent_run, "memory_read")
    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_includes call.error_detail, provider.public_id
    assert_includes call.error_detail, "nexus.memory"
    assert_nil call.addressed_executor_id
    assert_equal "running", node(agent_run, "r1").status, "the model reads it on the next round"
    assert_empty MemoryDocument.where(workspace_id: @workspace.id), "the kernel ran nothing"
  end

  # Level-triggered drift: a re-announcement that drops one verb fails THAT verb's calls; the others
  # still ride to the provider.
  test "a provider that dropped a verb fails that verb only" do
    provider = memory_provider
    override!(provider)
    assert_predicate provider.announce(tools: memory_entries(MEMORY_NAMES - ["memory_ls"])), :accepted?

    dropped = seed(memory_model("round1"))
    start!(dropped)
    call = memory_call!(dropped, "memory_ls")
    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_includes call.error_detail, "does not announce memory_ls"

    kept = seed(memory_model("round1"))
    start!(kept)
    call = memory_call!(kept, "memory_read")
    assert_equal "dispatched", call.status
    assert_equal provider.id, call.addressed_executor_id
  end

  # Risk 1's pin: a reserved name never consults the map — the read answers
  # nil for it, so `wait` under an override is still the kernel's.
  test "a reserved name never consults the override" do
    provider = memory_provider
    override!(provider)
    assert_nil @workspace.reload.tool_provider_override_for("wait")
    agent_run = seed(memory_model("round1"))
    start!(agent_run)

    call = fan!(agent_run, "wait")
    assert_equal "running", call.status
    assert_nil call.addressed_executor_id
    assert_equal Nexus::ToolRegistry::GRAPH_WRITE, call.effect_profile
  end

  # The scope rule's admitted private case, seen from addressing: a
  # `user_private` provider under the owner of a private workspace serves
  # every principal that can reach the workspace — the owner and the
  # agents the owner stewards.
  test "on the admitted private workspace every accessible principal is served" do
    dedicated = workspaces(:dedicated)
    provider = memory_provider(manager: users(:owner), assignment_scope: :user_private)
    override!(provider, workspace: dedicated)

    as_owner = seed(memory_model("round1"), workspace: dedicated, creating_user: users(:owner))
    start!(as_owner, acting_user: users(:owner))
    assert_equal provider.id, memory_call!(as_owner, "memory_read").addressed_executor_id

    as_agent = seed(memory_model("round1"), workspace: dedicated, creating_user: @agent)
    start!(as_agent, acting_user: @agent)
    assert_equal provider.id, memory_call!(as_agent, "memory_read").addressed_executor_id
  end

  # Default changes never re-address accepted work, including provider overrides.
  test "a default change never re-addresses an overridden row" do
    provider = memory_provider
    override!(provider)
    agent_run = seed(memory_model("round1"))
    start!(agent_run)
    call = memory_call!(agent_run, "memory_read")
    assert_equal provider.id, call.addressed_executor_id

    second = connect_runner(manager: users(:owner), registration_identifier: "test-runner-2",
      assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate second.announce(tools: TEST_SERVED_TOOLS), :accepted?
    result = Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: agent_run, executor_public_id: second.public_id, acting_user: @human
    ))
    assert_equal :accepted, result.outcome
    assert_equal provider.id, call.reload.addressed_executor_id
    assert_equal "dispatched", call.status
  end

  # THE PRINCIPAL IS THE ANSWERER: a loop-backed loop a Human authored on a conversation the owner's
  # agent answers is served by the owner's private runner — the binding written for the answerer at
  # create must be reachable at every call; the speaker stays the loop's creator. (The
  # overridden-kernel branch reads the same word; no lawful world separates the two judgments there
  # — an override admits a private provider only on the private workspace every accessible principal
  # is served on, the case above.)
  test "a loop-backed loop is addressed for its conversation's ANSWERER, never its speaker" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private",
      assignment_scope: :user_private).executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      default_runner_executor: owners_private)

    agent_run = create_answered_loop(tool("t"), conversation: answered, acting_user: @human)

    assert_equal @human, agent_run.creating_user, "the speaker stays the loop's creator"
    assert_equal @agent, agent_run.answering_user
    call = node(agent_run, "t")
    assert_equal "dispatched", call.status
    assert_equal owners_private.id, call.addressed_executor_id, "the owner's private runner serves the agent the owner stewards"
  end

  test "a loop-backed loop is addressed for its TURN's answerer; the conversation's default never enters" do
    owners_private = connect_runner(manager: users(:owner), registration_identifier: "owner-private",
      assignment_scope: :user_private).executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    plain = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: owners_private)

    agent_run = create_answered_loop(tool("t"), conversation: plain, acting_user: @human, answering_user: @agent)

    assert_equal [@human, @agent, @human], [plain.answering_user, agent_run.answering_user, agent_run.creating_user]
    assert_equal ["dispatched", owners_private.id], [node(agent_run, "t").status, node(agent_run, "t").addressed_executor_id]
    assert_equal agent_address, Executors::Address.agent_address(agent_run),
      "the agent address derives from the turn's declaring profile"
  end
  # ── the source-routed name: `skill` ──
  #
  # Skill dispatch uses the catalog captured at acceptance. Explicit Runner
  # callables retain their selected Runner; kernel skill declarations freeze
  # Agent, workspace or user precedence. No later announcement changes source.
  # An executor source must still serve `skill`; no provider pool fallback.

  DOCUMENT = { "name" => "deploy-notes", "description" => "How this project is deployed." }.freeze
  SKILL_ENTRY = { "name" => "skill", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                  "timeout_ms" => 15_000 }.freeze
  # Claude Code's spelling of the load (rho's `claude` preset): `Skill({skill})`
  # mapped onto the kernel's `name`.
  SKILL_ALIAS = { "type" => "function", "function" => { "name" => "Skill" }, "canonical" => "nexus.skill.load",
                  "params" => { "skill" => { "maps_to" => "name",
                                             "description" => "The skill name. E.g., \"commit\", \"review-pr\", or \"pdf\"" } } }.freeze

  def skill_model(key, entry: Nexus::Tools::SKILL)
    { "model" => { "key" => key, "model" => MOCK_MODEL, "prompt" => "p",
                   "tools" => [Nexus::ToolRegistry.function_definition("wait"), entry] } }
  end

  def routed_skill(runner, name = "runner_skill")
    Nexus::Tools::SKILL.deep_dup.tap do |entry|
      entry.fetch("function")["name"] = name
      entry["route"] = { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => "skill" }
    end
  end

  def skill_call!(agent_run, input, called: "skill", key: "round1")
    apply_via(step_attempt(agent_run, key), sse_success("loading", tool_calls: [
      { id: "call_skill", name: called, arguments: input.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    agent_run.agent_run_tasks.find_by!(tool_call_id: "call_skill")
  end

  test "a Runner skill callable keeps the source target and appears in the inbox" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    run = seed(skill_model("round1", entry: routed_skill(runner)))
    start!(run)
    call = skill_call!(run, { name: "deploy-notes" }, called: "runner_skill")
    assert_equal "dispatched", call.status
    assert_equal runner.id, call.addressed_executor_id
    assert_equal runner.public_id, call.target_executor_public_id
    assert_equal "runner", call.addressed_role
    assert_equal runner.effect_profile_for("skill"), call.effect_profile
    row = Executors::Inbox.row(call)
    assert_equal "skill", row.fetch(:tool_name)
    assert_equal "runner_skill", row.fetch(:tool_alias)
    assert_equal({ "name" => "deploy-notes" }, row.fetch(:tool_input))
    assert_equal runner.public_id, row.dig(:target, :executor_public_id)
  end

  test "a kernel skill alias still maps inputs on the frozen Agent source" do
    announce_on_address!(AGENT_ONLY)
    assert_predicate agent_address.announce(tools: [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    run = seed(skill_model("round1", entry: SKILL_ALIAS), creating_user: @agent)
    start!(run, acting_user: @agent)
    call = skill_call!(run, { skill: "deploy-notes" }, called: "Skill")
    assert_equal "skill", call.tool_name
    assert_equal "Skill", call.tool_alias
    assert_equal({ "name" => "deploy-notes" }, call.tool_input)
    assert_equal "dispatched", call.status
    assert_equal agent_address.id, call.addressed_executor_id
  end

  test "a Runner skill reads only the originating frozen document catalog" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    run = seed(skill_model("round1", entry: routed_skill(runner)))
    start!(run)
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY],
      documents: [DOCUMENT, { "name" => "later-notes", "description" => "Published later." }]), :accepted?

    call = skill_call!(run, { name: "later-notes" }, called: "runner_skill")

    assert_equal "runner_skill", call.tool_alias
    assert_equal runner.public_id, call.target_executor_public_id
    assert_equal %w[failed tool_not_served], call.values_at(:status, :error_key)
    assert_nil call.addressed_executor_id
  end

  test "a Runner withdrawing its skill capability fails without selecting another source" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    run = seed(skill_model("round1", entry: routed_skill(runner)))
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS, documents: [DOCUMENT]), :accepted?
    start!(run)
    call = skill_call!(run, { name: "deploy-notes" }, called: "runner_skill")
    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_nil call.addressed_executor_id
    assert_nil call.deadline_at
    assert_equal :resolved, AgentRuns::Graph.settlement_of(call)
  end

  test "a name nobody announced runs in-process with the registry's profile, whatever the runner serves" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    agent_run = seed(skill_model("round1"))
    start!(agent_run)

    call = skill_call!(agent_run, { name: "commit-style" })
    assert_equal "running", call.status, "the kernel's own rows answer it (Memory::Run#skill)"
    assert_nil call.addressed_executor_id
    assert_nil call.addressed_role
    assert_equal Nexus::ToolRegistry::READ_ONLY_CLOSED, call.effect_profile
    assert_enqueued_with(job: AgentRuns::MemoryJob, args: [call.id]) do
      AgentRuns::Dispatch.after_commit(call)
    end

    malformed = seed(skill_model("round1"))
    start!(malformed)
    call = skill_call!(malformed, { name: ["not", "a", "name"] })
    assert_equal "running", call.status, "a malformed name matches no announcement: the executor answers skill_unknown"
    assert_nil call.addressed_executor_id
  end

  test "a plain skill keeps the Agent source even when a Runner later announces the same name" do
    announce_on_address!(AGENT_ONLY)
    assert_predicate agent_address.announce(tools: [
      { "name" => AGENT_ONLY, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }, SKILL_ENTRY,
    ], documents: [{ "name" => "echo-notes", "description" => "The address's own." }, DOCUMENT]), :accepted?
    agent_run = seed(skill_model("round1"), creating_user: @agent)
    start!(agent_run, acting_user: @agent)

    call = skill_call!(agent_run, { name: "echo-notes" })
    assert_equal "dispatched", call.status
    assert_equal agent_address.id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role
    assert_equal agent_address.effect_profile_for("skill"), call.effect_profile

    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    both = seed(skill_model("round1"), creating_user: @agent)
    start!(both, acting_user: @agent)
    call = skill_call!(both, { name: "deploy-notes" })
    assert_equal agent_address.id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role
  end

  # The route reads the ANNOUNCEMENTS and never the workspace map: a
  # `nexus.memory` override changes nothing for `skill`, and the map can
  # never name `nexus.skill` (Workspace refuses it).
  test "the override map never enters the skill route" do
    provider = memory_provider
    override!(provider)
    assert_nil @workspace.reload.tool_provider_override_for("skill")
    agent_run = seed(skill_model("round1"))
    start!(agent_run)

    call = skill_call!(agent_run, { name: "deploy-notes" })
    assert_equal "running", call.status
    assert_nil call.addressed_executor_id, "not the memory provider, not the runner: nobody announced the name"
  end
  test "a memory override cannot restore a disabled execution's roots" do
    override!(memory_provider)
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:member))
    seam = create_run_backed_turn(conversation: conversation, acting_user: users(:member))
    seam.variant.update!(memory_context: { "bindings" => [] })
    grow!(seam.agent_run, memory_model("round1"))
    schedule!(seam.agent_run)

    call = memory_call!(seam.agent_run, "memory_read")
    assert_equal "failed", call.status
    assert_equal "memory_scope_unavailable", call.error_key
    assert_nil call.addressed_executor_id
    assert_equal({ bindings: [] }, Executors::Inbox.scope_of(call))
  end

  test "a memory override refuses writes through a read binding" do
    override!(memory_provider)
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:member))
    seam = create_run_backed_turn(conversation: conversation, acting_user: users(:member))
    seam.variant.update!(memory_context: { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read" },
    ] })
    grow!(seam.agent_run, memory_model("round1"))
    schedule!(seam.agent_run)

    call = memory_call!(seam.agent_run, "memory_write", path: "conversation/notes.md")
    assert_equal "failed", call.status
    assert_equal "memory_read_only", call.error_key
    assert_nil call.addressed_executor_id
    assert_equal "read", Executors::Inbox.scope_of(call).fetch(:bindings).sole.fetch(:access)
  end
end
