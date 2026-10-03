require "test_helper"

# ONE ADDRESSING SITE: at a parked node's start the kernel writes WHO it is addressed to on the row
# — kernel job, the host's bound runner, the loop's agent address — or fails it `tool_not_served`,
# an error the model reads on the next round. The inbox and the claim read the row; nothing
# downstream asks the registry again.
class AgentLoops::AddressingTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

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
    super(key, "tools" => [Nexus::Compose::DEFINITION, Nexus::Tools::ASK, declared(UNSERVED)], **over)
  end

  def declared(name)
    { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
  end

  def start!(agent_loop, acting_user: @human)
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

  # A round that calls `name` once, expanded and scheduled: the fan member
  # starts — addressed or failed — and the continuation waits on it.
  def fan!(agent_loop, name, key: "round1")
    apply_via(step_attempt(agent_loop, key), sse_success("calling", tool_calls: [
      { id: "call_#{name}", name: name, arguments: "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
    agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_#{name}")
  end

  # The model's flat `ask` — the tokenless await the kernel's job appends.
  def ask!(agent_loop, key: "round1")
    apply_via(step_attempt(agent_loop, key), sse_success("asking", tool_calls: [
      { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::AwaitTask.sti_name).sole
  end

  def agent_address = TaskExecutor.address_for(@agent)

  # The agent's own address announcing `names`, credential-ready.
  def announce_on_address!(*names) = announce_tools!(@agent, names)

  test "a kernel name runs in-process with the registry's profile frozen and no addressee" do
    agent_loop = seed(model("round1", "prompt" => "go"))
    start!(agent_loop)
    call = fan!(agent_loop, "compose")

    assert_equal "running", call.status
    assert_nil call.addressed_executor_id
    assert_nil call.addressed_role
    assert_equal Nexus::ToolRegistry::GRAPH_WRITE, call.effect_profile
  end

  test "a name the bound runner announces is dispatched to the runner with the announcement frozen" do
    runner = suite_runner
    runner.announce(tools: [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                              "timeout_ms" => 45_000 }])
    agent_loop = seed(tool("t"))
    assert_equal runner.id, agent_loop.runner_executor_id, "the runner the seed named is the initial binding"
    start!(agent_loop)

    call = node(agent_loop, "t")
    assert_equal "dispatched", call.status
    assert_equal runner.id, call.addressed_executor_id
    assert_equal "runner", call.addressed_role
    assert_equal runner.effect_profile_for("read_file"), call.effect_profile
    assert_equal 45_000, call.effect_profile.fetch("timeout_ms"), "the announced timeout rides the frozen profile"
    assert_equal 45_000, call.effective_timeout_ms, "and is the deadline's second source"
  end

  test "a name only the agent address announces is dispatched to the agent application" do
    agent_loop = seed(tool("t", AGENT_ONLY), creating_user: @agent)
    assert_equal suite_runner.id, agent_loop.runner_executor_id, "the seed named the runner; the address is no binding"
    announce_on_address!(AGENT_ONLY)
    start!(agent_loop, acting_user: @agent)

    call = node(agent_loop, "t")
    assert_equal "dispatched", call.status
    assert_equal agent_address.id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role
    assert_equal agent_address.effect_profile_for(AGENT_ONLY), call.effect_profile
  end

  # On a standalone agent-created host: an address that announced BEFORE the create is still not the
  # binding — eligibility is a row fact, never an announcement — and its own name reaches it as the
  # agent application's tool.
  test "an agent address that announced before create is still not the binding" do
    announce_on_address!(AGENT_ONLY)
    agent_loop = seed(tool("t", AGENT_ONLY), creating_user: @agent)
    assert_equal suite_runner.id, agent_loop.runner_executor_id,
      "the named runner-kind row — an announced agent address is never a binding"
    start!(agent_loop, acting_user: @agent)

    call = node(agent_loop, "t")
    assert_equal "dispatched", call.status
    assert_equal agent_address.id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role
  end

  # E3's unit twin: the binding is what a handoff moves, so it must win
  # over the agent's own announcement for a name both announce.
  test "the bound runner wins over the agent address for a name both announce" do
    agent_loop = seed(tool("t"), creating_user: @agent)
    announce_on_address!("read_file")
    assert_equal suite_runner.id, agent_loop.runner_executor_id
    start!(agent_loop, acting_user: @agent)

    call = node(agent_loop, "t")
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
    agent_loop = seed(tool("t", POOLED))
    assert_equal suite_runner.id, agent_loop.runner_executor_id, "a provider is never the binding"
    start!(agent_loop)

    call = node(agent_loop, "t")
    assert_equal "dispatched", call.status
    assert_nil call.addressed_executor_id, "a pool row names no executor"
    assert_equal "tools_provider", call.addressed_role
    assert_equal WRITE_PROFILE.merge("timeout_ms" => 30_000), call.effect_profile
    assert_not_predicate call, :replayable?
    assert_equal 30_000, call.effective_timeout_ms
  end

  test "two members with one replayable profile collapse to it" do
    entry = { "name" => POOLED, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED, "timeout_ms" => 45_000 }
    connect_provider(identifier: "pool-a", tools: [entry])
    connect_provider(identifier: "pool-b", tools: [entry.merge("timeout_ms" => 90_000)])
    agent_loop = seed(tool("t", POOLED))
    start!(agent_loop)

    call = node(agent_loop, "t")
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
    assert_equal "tools_provider", node(stewarded, "t").addressed_role,
      "the agent the manager stewards is served"
  end

  # Arms 2 and 3 come first: a provider announcing a bound name never
  # takes it from the binding or the agent's own address.
  test "the bound runner and the agent address win over a provider for a name both announce" do
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
    agent_loop = seed(model("round1", "prompt" => "go"), model("m2", "prompt" => "then"))
    start!(agent_loop)
    call = fan!(agent_loop, UNSERVED)

    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_equal "no executor announces #{UNSERVED} for this principal", call.error_detail
    assert_equal "absorb", call.on_failure, "a fan member absorbs by default"
    assert_nil call.failure_resolution
    assert_equal :resolved, AgentLoops::Graph.settlement_of(call)
    assert_nil call.addressed_executor_id
    assert_nil call.deadline_at, "it never parked"

    continuation = node(agent_loop, "r1")
    assert_equal "running", continuation.status, "the continuation is released, not stranded"
    build(step_attempt(agent_loop, continuation.node_key))
    result = round_request_entries(continuation).find { |payload| payload["type"] == "tool_result_item" }
    assert_equal "<tool_use_error>The tool call could not run. (tool_not_served) " \
                 "no executor announces #{UNSERVED} for this principal</tool_use_error>",
      result.dig("payload", "output")
  end

  test "a client-authored task with propagate skips its successors instead" do
    agent_loop = seed(tool("t", UNSERVED, "on_failure" => "propagate"), model("after", "prompt" => "then"))
    start!(agent_loop)

    assert_equal "failed", node(agent_loop, "t").status
    assert_equal "tool_not_served", node(agent_loop, "t").error_key
    assert_equal "skipped", node(agent_loop, "after").status
  end

  test "a runner that is revoked, credential-less, or private to another Human is not addressed" do
    bare = @account.task_executors.create!(
      executor_kind: :runner, display_name: "Bare", runner_identifier: "bare",
      manager: users(:owner), assignment_scope: :account_wide
    )
    foreign = connect_runner(manager: users(:owner), runner_identifier: "owner-private",
      assignment_scope: :user_private).executor_access_token.task_executor
    [bare, foreign].each do |runner|
      assert_predicate runner.announce(tools: TEST_SERVED_TOOLS), :accepted?
    end
    revoked = suite_runner
    revoked.revoke

    { "credential-less" => bare, "foreign user_private" => foreign, "revoked" => revoked }.each do |label, runner|
      # Unnamed (the suite's runner is revoked, and naming it would refuse):
      # the binding under test is written by hand below.
      agent_loop = seed(tool("t"), runner_executor_public_id: nil)
      agent_loop.update!(runner_executor: runner)
      start!(agent_loop)
      call = node(agent_loop, "t")
      assert_equal "failed", call.status, label
      assert_equal "tool_not_served", call.error_key, label
    end
  end

  test "a nil binding on a Human loop with no agent address is tool_not_served" do
    agent_loop = seed(tool("t"))
    agent_loop.update!(runner_executor: nil)
    start!(agent_loop)

    assert_equal "tool_not_served", node(agent_loop, "t").error_key
  end

  # The addressee is frozen per execution generation: a re-announcement after dispatch retargets
  # nothing already handed out.
  test "the addressee stands across a re-announcement" do
    agent_loop = seed(tool("t"))
    start!(agent_loop)
    call = node(agent_loop, "t")
    frozen = call.effect_profile

    assert_predicate suite_runner.announce(tools: []), :accepted?
    schedule!(agent_loop)
    call.reload
    assert_equal suite_runner.id, call.addressed_executor_id
    assert_equal frozen, call.effect_profile
    assert_equal "dispatched", call.status
  end

  test "a retry re-addresses the next generation at its start" do
    first = suite_runner
    agent_loop = seed(tool("t", "on_failure" => "propagate"))
    start!(agent_loop)
    assert_equal first.id, node(agent_loop, "t").addressed_executor_id
    AgentLoops::Parks::Settle.call(node: node(agent_loop, "t"), trusted: true, content: "boom", outcome: "failed")

    second = connect_runner(manager: users(:owner), runner_identifier: "test-runner-2",
      assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate second.announce(tools: TEST_SERVED_TOOLS), :accepted?
    first.revoke
    # This fixture moves the binding directly to isolate addressing from the handoff workflow.
    agent_loop.update!(runner_executor: second)

    first_grant = node(agent_loop, "t").approval_decided_at
    assert_not_nil first_grant
    retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "t", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    requeued = node(agent_loop, "t")
    assert_nil requeued.approval_origin, "the grant was the first generation's: the next crosses the stage anew"
    assert_nil requeued.approval_decided_at
    schedule!(agent_loop)

    call = node(agent_loop, "t")
    assert_equal "dispatched", call.status
    assert_equal second.id, call.addressed_executor_id
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

  # A round offering the kernel's own memory tools (and `compose`), so the
  # declared-only gate admits the call and the branch is what decides it.
  def memory_model(key)
    { "model" => { "key" => key, "model" => MOCK_MODEL, "prompt" => "p",
                   "tools" => [Nexus::Compose::DEFINITION,
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

  def memory_call!(agent_loop, name, key: "round1", path: "workspace/notes.md")
    apply_via(step_attempt(agent_loop, key), sse_success("calling", tool_calls: [
      { id: "call_#{name}", name: name, arguments: { path: path }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
    agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_#{name}")
  end

  test "an overridden namespace is addressed to the named provider with its announced profile frozen" do
    provider = memory_provider
    override!(provider)
    agent_loop = seed(memory_model("round1"))
    start!(agent_loop)

    call = memory_call!(agent_loop, "memory_read")
    assert_equal "dispatched", call.status
    assert_equal provider.id, call.addressed_executor_id
    assert_equal "tools_provider", call.addressed_role
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
    agent_loop = seed(memory_model("round1"))
    start!(agent_loop)

    call = memory_call!(agent_loop, "memory_read")
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
    agent_loop = seed(memory_model("round1"), model("m2", "prompt" => "then"))
    start!(agent_loop)

    call = memory_call!(agent_loop, "memory_read")
    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_includes call.error_detail, provider.public_id
    assert_includes call.error_detail, "nexus.memory"
    assert_nil call.addressed_executor_id
    assert_equal "running", node(agent_loop, "r1").status, "the model reads it on the next round"
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
  # nil for it, so `compose` under an override is still the kernel's.
  test "a reserved name never consults the override" do
    provider = memory_provider
    override!(provider)
    assert_nil @workspace.reload.tool_provider_override_for("compose")
    agent_loop = seed(memory_model("round1"))
    start!(agent_loop)

    call = fan!(agent_loop, "compose")
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

  # A handoff re-addresses `addressed_role: runner` rows only: an overridden
  # row is the provider's, and the binding's move never touches it.
  test "a handoff never re-addresses an overridden row" do
    provider = memory_provider
    override!(provider)
    agent_loop = seed(memory_model("round1"))
    start!(agent_loop)
    call = memory_call!(agent_loop, "memory_read")
    assert_equal provider.id, call.addressed_executor_id

    second = connect_runner(manager: users(:owner), runner_identifier: "test-runner-2",
      assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate second.announce(tools: TEST_SERVED_TOOLS), :accepted?
    result = Executors::Handoff.call(Executors::Handoff::Command.new(
      host: agent_loop, executor_public_id: second.public_id, acting_user: @human
    ))
    assert_equal :accepted, result.outcome
    assert_empty result.value.readdressed
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
    owners_private = connect_runner(manager: users(:owner), runner_identifier: "owner-private",
      assignment_scope: :user_private).executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      runner_executor: owners_private)

    agent_loop = create_answered_loop(tool("t"), conversation: answered, acting_user: @human)

    assert_equal @human, agent_loop.creating_user, "the speaker stays the loop's creator"
    assert_equal @agent, agent_loop.answering_user
    call = node(agent_loop, "t")
    assert_equal "dispatched", call.status
    assert_equal owners_private.id, call.addressed_executor_id, "the owner's private runner serves the agent the owner stewards"
  end

  test "a loop-backed loop is addressed for its TURN's answerer; the conversation's default never enters" do
    owners_private = connect_runner(manager: users(:owner), runner_identifier: "owner-private",
      assignment_scope: :user_private).executor_access_token.task_executor
    assert_predicate owners_private.announce(tools: TEST_SERVED_TOOLS), :accepted?
    plain = Conversation.create!(workspace: @workspace, creating_user: @human, runner_executor: owners_private)

    agent_loop = create_answered_loop(tool("t"), conversation: plain, acting_user: @human, answering_user: @agent)

    assert_equal [@human, @agent, @human], [plain.answering_user, agent_loop.answering_user, agent_loop.creating_user]
    assert_equal ["dispatched", owners_private.id], [node(agent_loop, "t").status, node(agent_loop, "t").addressed_executor_id]
    assert_equal agent_address, Executors::Address.agent_address(agent_loop),
      "the agent address derives from the turn's declaring profile"
  end
  # ── the source-routed name: `skill` ──
  #
  # The one kernel tool addressed PER CALL by its argument: `Skills::
  # Dispatch.address` reads the call's `name` as an ADDRESS — is it a name
  # the bound runner or the agent address announced under `documents`? —
  # and the SAME `skill` row is dispatched to that announcer, or runs
  # in-process for every other name. Decided before the override map;
  # never a pool; the announcer must serve `skill` (else `tool_not_served`).

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
                   "tools" => [Nexus::Compose::DEFINITION, entry] } }
  end

  def skill_call!(agent_loop, input, called: "skill", key: "round1")
    apply_via(step_attempt(agent_loop, key), sse_success("loading", tool_calls: [
      { id: "call_skill", name: called, arguments: input.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
    agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_skill")
  end

  test "a skill the bound runner announced is dispatched to the runner as the same row, listed with its scope" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    agent_loop = seed(skill_model("round1"))
    start!(agent_loop)

    call = skill_call!(agent_loop, { name: "deploy-notes" })
    assert_equal "dispatched", call.status
    assert_equal runner.id, call.addressed_executor_id
    assert_equal "runner", call.addressed_role
    assert_equal runner.effect_profile_for("skill"), call.effect_profile, "the ANNOUNCED profile, not the registry's"
    assert_equal 15_000, call.effective_timeout_ms

    row = Executors::Inbox.row(call)
    assert_equal "skill", row.fetch(:tool_name)
    assert_nil row[:tool_alias]
    assert_equal({ "name" => "deploy-notes" }, row.fetch(:tool_input), "tool_input passes through untouched")
    assert_equal({ workspace_public_id: @workspace.public_id, conversation_public_id: nil,
                   user_public_id: @human.public_id }, row.fetch(:scope), "a kernel-named row carries the stamp")
    assert_equal({ role: "runner", executor_public_id: runner.public_id }, row.fetch(:addressed_to))
  end

  test "an alias of the load (Claude Code's Skill) is dispatched by the kernel's name with the alias beside it" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    agent_loop = seed(skill_model("round1", entry: SKILL_ALIAS))
    start!(agent_loop)

    call = skill_call!(agent_loop, { skill: "deploy-notes" }, called: "Skill")
    assert_equal "skill", call.tool_name
    assert_equal "Skill", call.tool_alias
    assert_equal({ "name" => "deploy-notes" }, call.tool_input, "the alias map moved `skill` onto `name`")
    assert_equal "dispatched", call.status
    assert_equal runner.id, call.addressed_executor_id
    assert_equal "Skill", Executors::Inbox.row(call).fetch(:tool_alias)
  end

  test "an announcer that does not serve skill fails a load of its names tool_not_served, naming it" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS, documents: [DOCUMENT]), :accepted?
    agent_loop = seed(skill_model("round1"), model("m2", "prompt" => "then"))
    start!(agent_loop)

    call = skill_call!(agent_loop, { name: "deploy-notes" })
    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_equal "deploy-notes is announced by #{runner.display_name}, which does not serve skill", call.error_detail
    assert_nil call.addressed_executor_id
    assert_nil call.deadline_at, "it never parked"
    assert_equal :resolved, AgentLoops::Graph.settlement_of(call)
  end

  test "a name nobody announced runs in-process with the registry's profile, whatever the runner serves" do
    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    agent_loop = seed(skill_model("round1"))
    start!(agent_loop)

    call = skill_call!(agent_loop, { name: "commit-style" })
    assert_equal "running", call.status, "the kernel's own rows answer it (Memory::Run#skill)"
    assert_nil call.addressed_executor_id
    assert_nil call.addressed_role
    assert_equal Nexus::ToolRegistry::READ_ONLY_CLOSED, call.effect_profile
    assert_enqueued_with(job: AgentLoops::MemoryJob, args: [call.id]) do
      AgentLoops::Dispatch.after_commit(call)
    end

    malformed = seed(skill_model("round1"))
    start!(malformed)
    call = skill_call!(malformed, { name: ["not", "a", "name"] })
    assert_equal "running", call.status, "a malformed name matches no announcement: the executor answers skill_unknown"
    assert_nil call.addressed_executor_id
  end

  test "a name the agent address announced is dispatched to the agent application; the runner precedes it" do
    agent_loop = seed(skill_model("round1"), creating_user: @agent)
    announce_on_address!(AGENT_ONLY)
    assert_predicate agent_address.announce(tools: [
      { "name" => AGENT_ONLY, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }, SKILL_ENTRY,
    ], documents: [{ "name" => "echo-notes", "description" => "The address's own." }, DOCUMENT]), :accepted?
    start!(agent_loop, acting_user: @agent)

    call = skill_call!(agent_loop, { name: "echo-notes" })
    assert_equal "dispatched", call.status
    assert_equal agent_address.id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role
    assert_equal agent_address.effect_profile_for("skill"), call.effect_profile

    runner = suite_runner
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS + [SKILL_ENTRY], documents: [DOCUMENT]), :accepted?
    both = seed(skill_model("round1"), creating_user: @agent)
    start!(both, acting_user: @agent)
    call = skill_call!(both, { name: "deploy-notes" })
    assert_equal runner.id, call.addressed_executor_id, "both announced deploy-notes: the bound runner precedes the address"
    assert_equal "runner", call.addressed_role
  end

  # The route reads the ANNOUNCEMENTS and never the workspace map: a
  # `nexus.memory` override changes nothing for `skill`, and the map can
  # never name `nexus.skill` (Workspace refuses it).
  test "the override map never enters the skill route" do
    provider = memory_provider
    override!(provider)
    assert_nil @workspace.reload.tool_provider_override_for("skill")
    agent_loop = seed(skill_model("round1"))
    start!(agent_loop)

    call = skill_call!(agent_loop, { name: "deploy-notes" })
    assert_equal "running", call.status
    assert_nil call.addressed_executor_id, "not the memory provider, not the runner: nobody announced the name"
  end
  test "a memory override cannot restore a disabled execution's roots" do
    override!(memory_provider)
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:member))
    seam = create_loop_backed_turn(conversation: conversation, acting_user: users(:member))
    seam.variant.update!(memory_context: { "bindings" => [] })
    grow!(seam.agent_loop, memory_model("round1"))
    schedule!(seam.agent_loop)

    call = memory_call!(seam.agent_loop, "memory_read")
    assert_equal "failed", call.status
    assert_equal "memory_scope_unavailable", call.error_key
    assert_nil call.addressed_executor_id
    assert_equal({ bindings: [] }, Executors::Inbox.scope_of(call))
  end

  test "a memory override refuses writes through a read binding" do
    override!(memory_provider)
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:member))
    seam = create_loop_backed_turn(conversation: conversation, acting_user: users(:member))
    seam.variant.update!(memory_context: { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read" },
    ] })
    grow!(seam.agent_loop, memory_model("round1"))
    schedule!(seam.agent_loop)

    call = memory_call!(seam.agent_loop, "memory_write", path: "conversation/notes.md")
    assert_equal "failed", call.status
    assert_equal "memory_read_only", call.error_key
    assert_nil call.addressed_executor_id
    assert_equal "read", Executors::Inbox.scope_of(call).fetch(:bindings).sole.fetch(:access)
  end
end
