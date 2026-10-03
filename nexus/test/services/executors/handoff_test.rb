require "test_helper"

# THE HANDOFF: one guarded write of the host's runner binding, narrated `runner_bound`, then — per
# live loop, under that loop's own lock — every dispatched runner-kind row nobody has claimed is
# re-addressed through THE ONE addressing site with its park clock re-armed, narrated
# `task_readdressed` and nudged; a name the new runner lacks fails through FailNode; a claimed row
# settles where it started. Two transactions, never a lock across hosts and loops.
class Executors::HandoffTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopSeamTestHelper

  READ_TIMEOUT_MS = 90_000

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read", **over) = super(key, name, "input" => { "path" => key }, **over)

  # Runner A is the suites' announcer; runner B is a second account-wide
  # runner announcing `read` alone, with its own park.
  def runner_a = suite_runner

  def runner_b
    @runner_b ||= connect_runner(manager: @owner, runner_identifier: "runner-b",
      display_name: "Runner B", assignment_scope: :account_wide)
      .executor_access_token.task_executor.tap do |runner|
        announce!(runner, [{ "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                             "timeout_ms" => READ_TIMEOUT_MS }])
      end
  end

  def announce!(executor, entries)
    outcome = executor.announce(tools: entries)
    assert_predicate outcome, :accepted?, outcome.outcome.to_s
  end

  # A standalone loop bound to runner A from birth, its tool rows started —
  # dispatched to A, unclaimed.
  def standalone_on_a(*steps, creating_user: @human)
    agent_loop = seed(*steps, creating_user: creating_user, runner_executor_public_id: runner_a.public_id)
    start!(agent_loop, acting_user: creating_user)
    agent_loop
  end

  def start!(agent_loop, acting_user: @human)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: acting_user))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  # A conversation bound to runner A with one loop-backed loop whose rows
  # are started the same way.
  def conversation_on_a(*steps, creating_user: @human, answering_user: creating_user, workspace: @workspace)
    runner_a
    conversation = Conversation.create!(workspace: workspace, creating_user: creating_user,
      answering_user: answering_user, runner_executor: runner_a)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: creating_user)
    grow!(seam.agent_loop, *steps) if steps.any?
    AgentLoops::ScheduleReady.call(agent_loop_id: seam.agent_loop.id)
    clear_enqueued_jobs
    [conversation, seam.agent_loop]
  end

  def handoff(host, executor_public_id, by: @human)
    Executors::Handoff.call(Executors::Handoff::Command.new(
      host: host, executor_public_id: executor_public_id, acting_user: by
    ))
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def items(host, type)
    host.conversation_event_items.where(item_type: type).order(:sequence).map(&:payload)
  end

  def executor_streams
    broadcasts = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { broadcasts << [stream, payload] }) { yield }
    broadcasts.select { |stream, _payload| stream.start_with?("agent_api:v1:executor:") }
  end

  def stream_of(executor) = AgentAPI::V1::ExecutorInboxChannel.stream_name(executor.public_id)

  # The frontier the sweep would scan at `now`: ids of parked rows whose
  # deadline has passed by the SQL twin's arithmetic.
  def swept_at(now)
    AgentLoopNode
      .joins("INNER JOIN agent_loops ON agent_loops.id = agent_loop_nodes.agent_loop_id")
      .where(type: AgentLoopNodes::PARKED_TYPES, status: AgentLoopNode::SWEPT_STATUSES)
      .where.not(await_started_at: nil)
      .where(AgentLoops::Parks::TimeoutSweep::FRONTIER_SQL,
        *AgentLoops::Parks::TimeoutSweep.frontier_binds, now)
      .pluck(:id)
  end

  # --- the effect: re-addressing through the one site ---------------------

  test "an unclaimed dispatched row is re-addressed to the new runner with its clock re-armed, narrated and nudged" do
    agent_loop = standalone_on_a(tool("r1"))
    row = node(agent_loop, "r1")
    assert_equal "dispatched", row.status
    assert_equal runner_a.id, row.addressed_executor_id
    assert_nil row.claimed_at
    before = row.deadline_at

    statuses_before = items(agent_loop, "task_status").select { |p| p["task_key"] == "r1" }

    travel 5.seconds
    re_arm = Time.current
    broadcasts = executor_streams { @result = handoff(agent_loop, runner_b.public_id) }

    assert_equal :accepted, @result.outcome
    assert_equal [{ agent_loop_public_id: agent_loop.public_id, task_key: "r1", outcome: :readdressed }],
      @result.value.readdressed.map(&:to_h)

    row.reload
    assert_equal runner_b.id, row.addressed_executor_id
    assert_equal "runner", row.addressed_role
    assert_equal "dispatched", row.status
    assert_equal runner_b.effect_profile_for("read"), row.effect_profile
    assert_equal READ_TIMEOUT_MS, row.effect_profile.fetch("timeout_ms")
    # BOTH readers agree (the sweep's SQL twin and Parked#deadline_at): the
    # deadline is the re-arm instant plus the NEW runner's park.
    assert_in_delta re_arm + READ_TIMEOUT_MS / 1000.0, row.deadline_at, 1.0
    assert_not_equal before, row.deadline_at, "the clock moved with the profile — never the profile alone"
    assert_not_includes swept_at(row.deadline_at - 1.second), row.id
    assert_includes swept_at(row.deadline_at + 1.second), row.id

    readdressed = items(agent_loop, "task_readdressed")
    assert_equal [{ "task_key" => "r1", "role" => "runner", "executor_public_id" => runner_b.public_id,
                    "deadline_at" => row.deadline_at.iso8601,
                    "agent_loop_public_id" => agent_loop.public_id }], readdressed
    # `task_readdressed` is the ONE item of the re-address — the status did not move, and no
    # same-status `task_status` rides beside it.
    assert_equal statuses_before, items(agent_loop, "task_status").select { |p| p["task_key"] == "r1" },
      "the re-address narrated a task_status the row's status does not justify"
    assert_equal %w[waiting needs_approval dispatched], statuses_before.map { |p| p["status"] },
      "the seed's birth, the stage that granted it by its origin, and its dispatch"

    streams = broadcasts.map(&:first)
    assert_equal [stream_of(runner_b)], streams, "nudged ONCE, on the new runner's stream alone"
    assert_equal "work_available", broadcasts.sole.last.dig(:event, :type)
    assert_equal "r1", broadcasts.sole.last.dig(:event, :task_key)
  end

  test "runner_bound rides the host feed with the three keys, and the binding is readable" do
    agent_loop = standalone_on_a(tool("r1"))

    handoff(agent_loop, runner_b.public_id)

    assert_equal [{ "executor_public_id" => runner_b.public_id,
                    "previous_executor_public_id" => runner_a.public_id,
                    "by" => @human.public_id }], items(agent_loop, "runner_bound")
    assert_equal runner_b, agent_loop.reload.bound_runner
  end

  test "a conversation host re-addresses its loop-backed loop's rows and narrates on its own feed" do
    conversation, agent_loop = conversation_on_a(tool("r1"))
    row = node(agent_loop, "r1")
    assert_equal runner_a.id, row.addressed_executor_id

    result = handoff(conversation, runner_b.public_id)

    assert_equal :accepted, result.outcome
    assert_equal runner_b.id, row.reload.addressed_executor_id
    assert_equal runner_b, agent_loop.reload.bound_runner, "a loop-backed loop reads its conversation's binding"
    assert_equal [runner_b.public_id], items(conversation, "runner_bound").map { |p| p["executor_public_id"] }
    assert_equal ["r1"], items(conversation, "task_readdressed").map { |p| p["task_key"] }
  end

  test "the same id is accepted unchanged: no item, no pass" do
    agent_loop = standalone_on_a(tool("r1"))
    before = node(agent_loop, "r1").await_started_at

    travel 5.seconds
    result = handoff(agent_loop, runner_a.public_id)

    assert_equal :accepted, result.outcome
    assert_equal agent_loop, result.value.host
    assert_empty result.value.readdressed, "no pass"
    assert_empty items(agent_loop, "runner_bound")
    assert_empty items(agent_loop, "task_readdressed")
    assert_equal before, node(agent_loop, "r1").await_started_at
  end

  test "a nil previous binding hands off like any other, with no previous key" do
    runner_a
    runner_b
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    assert_nil conversation.runner_executor

    result = handoff(conversation, runner_b.public_id)

    assert_equal :accepted, result.outcome
    payload = items(conversation, "runner_bound").sole
    assert_equal runner_b.public_id, payload.fetch("executor_public_id")
    assert_not payload.key?("previous_executor_public_id")
  end

  test "a name the new runner lacks that nobody else serves fails through FailNode, honouring on_failure, and the loop drains" do
    agent_loop = standalone_on_a(tool("s1", "search", "on_failure" => "absorb"), model("after", "prompt" => "then"))
    assert_equal "dispatched", node(agent_loop, "s1").status
    assert_equal "queued", node(agent_loop, "after").status

    result = handoff(agent_loop, runner_b.public_id)

    assert_equal [{ agent_loop_public_id: agent_loop.public_id, task_key: "s1", outcome: :failed }],
      result.value.readdressed.map(&:to_h)
    failed = node(agent_loop, "s1")
    assert_equal "failed", failed.status
    assert_equal "tool_not_served", failed.error_key
    assert_equal "no executor announces search for this principal", failed.error_detail
    assert_nil failed.failure_resolution
    assert_equal :resolved, AgentLoops::Graph.settlement_of(failed), "absorb resolved it by policy"
    assert_equal "running", node(agent_loop, "after").status, "the released round started"
    assert_empty items(agent_loop, "task_readdressed")
  end

  test "a name the new runner lacks that a pool serves is re-addressed to the pool with the pool's frozen profile" do
    pool_entry = { "name" => "net_fetch", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                   "timeout_ms" => 5_000 }
    announce!(runner_a, LoopAuthoringTestHelper::TEST_SERVED_TOOLS + [pool_entry])
    provider = connect_provider(identifier: "pool-x", tools: [pool_entry])
    agent_loop = standalone_on_a(tool("f1", "net_fetch"))
    assert_equal runner_a.id, node(agent_loop, "f1").addressed_executor_id

    broadcasts = executor_streams { handoff(agent_loop, runner_b.public_id) }

    row = node(agent_loop, "f1")
    assert_nil row.addressed_executor_id
    assert_equal "tools_provider", row.addressed_role
    assert_equal Executors::Pool.effect_profile([provider], "net_fetch"), row.effect_profile
    assert_equal [stream_of(provider)], broadcasts.map(&:first)
    payload = items(agent_loop, "task_readdressed").sole
    assert_equal "tools_provider", payload.fetch("role")
    assert_not payload.key?("executor_public_id")
  end

  test "a claimed row is untouched: same addressee, same clock, no item" do
    agent_loop = standalone_on_a(parallel(tool("r1"), tool("r2")), model("after", "prompt" => "then"))
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: "r1", executor: runner_a
    ))
    assert_predicate claimed, :accepted?
    clock = node(agent_loop, "r1").await_started_at

    travel 5.seconds
    result = handoff(agent_loop, runner_b.public_id)

    row = node(agent_loop, "r1")
    assert_equal runner_a.id, row.addressed_executor_id
    assert_equal clock, row.await_started_at
    assert_equal ["r2"], result.value.readdressed.map(&:task_key)
    assert_equal ["r2"], items(agent_loop, "task_readdressed").map { |p| p["task_key"] }
    assert_equal runner_b.id, node(agent_loop, "r2").addressed_executor_id
  end

  # THE RACE (risk 1): a claim that lands between the host commit and the
  # loop lock is honoured because the pass selects `claimed_at IS NULL`
  # UNDER the loop lock — one statement, `FOR UPDATE` on the rows, after
  # the loop row is held — and the claim takes the same loop lock, so the
  # two serialize: a row claimed first is not in the set; a row re-addressed
  # first refuses the old runner `not_addressed_here`. A cross-connection
  # drive of this cannot run under transactional fixtures (the loop rows are
  # invisible to a second connection), so the pin is the statement's shape.
  test "the pass reads the unclaimed set on the locked rows, after the loop lock" do
    agent_loop = standalone_on_a(tool("r1"))
    runner_b

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql].to_s
    end
    handoff(agent_loop, runner_b.public_id)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    loop_locks = statements.each_index.select { |i| statements[i].match?(/FROM "agent_loops".*FOR UPDATE/m) }
    selection = statements.index do |sql|
      sql.include?(%("agent_loop_nodes"."claimed_at" IS NULL)) && sql.match?(/FOR UPDATE\s*\z/)
    end
    assert selection, "the unclaimed set is read on locked rows:\n#{statements.grep(/agent_loop_nodes/).join("\n")}"
    assert loop_locks.any? { |i| i < selection }, "the loop row is held before the rows are read"
    assert_equal runner_b.id, node(agent_loop, "r1").addressed_executor_id
  end

  # THE PAUSED CLOCK (`effective_now`): a re-arm on a paused loop is stamped
  # at the frozen clock, and `unfreeze` moves it to the resume instant
  # exactly as it moves every other parked row.
  test "a paused loop's row is re-armed at the frozen clock and reads right after resume" do
    agent_loop = standalone_on_a(tool("r1"))
    paused = AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(agent_loop: agent_loop, acting_user: @human))
    assert_predicate paused, :accepted?
    paused_at = agent_loop.reload.paused_at

    travel 30.seconds
    handoff(agent_loop, runner_b.public_id)
    row = node(agent_loop, "r1")
    assert_equal paused_at.floor(6), row.await_started_at.floor(6), "re-armed at the frozen clock, not wall time"
    assert_equal runner_b.id, row.addressed_executor_id

    travel 30.seconds
    resumed = AgentLoops::Resume.call(AgentLoops::Resume::Command.new(agent_loop: agent_loop, acting_user: @human))
    assert_predicate resumed, :accepted?
    assert_in_delta Time.current + READ_TIMEOUT_MS / 1000.0, node(agent_loop, "r1").deadline_at, 1.0
  end

  test "a fork after a handoff copies the new binding" do
    runner_a
    runner_b
    actor = Actors::Resolve.member(account: @account, user: @human)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, runner_executor: runner_a)
    turn = ConversationTurn.create!(account: @account, conversation: conversation, position: 0,
      kind: "message", role: "user", status: "completed", speaker_actor: actor, control_owner_user: @human)
    variant = ConversationTurnVariant.create!(account: @account, conversation_turn: turn, position: 0,
      status: "completed", source: "inference", content_preview: "hi")
    ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => "hi" }], seal: true)
    turn.update!(active_variant: variant)
    conversation.update!(timeline_position_head: 1)

    handoff(conversation, runner_b.public_id)
    forked = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: conversation, turn_public_id: turn.public_id, variant_public_id: nil,
      acting_user: @human, title: nil
    ))

    assert_equal :accepted, forked.outcome
    assert_equal runner_b.id, forked.value.runner_executor_id
  end

  # --- the caller rule ---------------------------------------------

  test "the host's ANSWERER on its own bearer binds; another agent is not_authorized" do
    conversation, agent_loop = conversation_on_a(tool("r1"), creating_user: @agent)
    other_agent = create_agent_member(steward: @owner, agent_identifier: "other-agent")

    refused = handoff(conversation, runner_b.public_id, by: other_agent)
    assert_equal :not_authorized, refused.outcome
    assert_equal runner_a, conversation.reload.bound_runner

    bound = handoff(conversation, runner_b.public_id, by: @agent)
    assert_equal :accepted, bound.outcome
    assert_equal runner_b.id, node(agent_loop, "r1").addressed_executor_id
    assert_equal @agent.public_id, items(conversation, "runner_bound").sole.fetch("by")

    # A Human's conversation the agent ANSWERS: the answerer binds, the creator's kind
    # notwithstanding; any other agent has no say.
    answered, = conversation_on_a(tool("a1"), creating_user: @human, answering_user: @agent)
    assert_equal :not_authorized, handoff(answered, runner_b.public_id, by: other_agent).outcome
    assert_equal :accepted, handoff(answered, runner_b.public_id, by: @agent).outcome
  end

  test "a Human with write standing binds an agent's host; a Human without has no standing" do
    conversation, = conversation_on_a(tool("r1"), creating_user: @agent)

    assert_equal :accepted, handoff(conversation, runner_b.public_id, by: @owner).outcome

    private_host = Conversation.create!(workspace: workspaces(:personal), creating_user: users(:curator),
      runner_executor: runner_a)
    refused = handoff(private_host, runner_b.public_id, by: @human)
    assert_equal :not_authorized, refused.outcome
    assert_equal runner_a, private_host.reload.bound_runner
  end

  # --- the target rule ---------------------------------------------

  # The fifth door the design missed: the handoff is a write on the host, so a Human the
  # conversation lists at `read` has no standing to bind — whatever the workspace says — while the
  # answerer stays full by derivation and binds on its own bearer.
  test "a Human the conversation lists at read cannot bind, workspace write standing notwithstanding" do
    conversation, = conversation_on_a(tool("r1"), creating_user: @agent)
    conversation.conversation_access_entries.create!(user: @owner, level: "read")

    refused = handoff(conversation, runner_b.public_id, by: @owner)
    assert_equal :not_authorized, refused.outcome
    assert_equal runner_a, conversation.reload.bound_runner
    assert_empty items(conversation, "runner_bound")

    assert_equal :accepted, handoff(conversation, runner_b.public_id, by: @agent).outcome
  end

  test "an unknown id, a tools provider and an agent address are runner_not_found" do
    agent_loop = standalone_on_a(tool("r1"))
    provider = connect_provider(identifier: "pool-p", tools: ["read"])

    assert_equal :runner_not_found, handoff(agent_loop, SecureRandom.uuid_v7).outcome
    assert_equal :runner_not_found, handoff(agent_loop, provider.public_id).outcome
    assert_equal :runner_not_found, handoff(agent_loop, task_executors(:address).public_id).outcome
    assert_equal runner_a, agent_loop.reload.bound_runner
    assert_empty items(agent_loop, "runner_bound")
  end

  test "an ineligible runner is runner_not_eligible naming the reason, and nothing moves" do
    agent_loop = standalone_on_a(tool("r1"))

    scoped = connect_runner(manager: @human, runner_identifier: "member-private", display_name: "Private")
      .executor_access_token.task_executor
    owners_loop = standalone_on_a(tool("o1"), creating_user: @owner)
    result = handoff(owners_loop, scoped.public_id, by: @owner)
    assert_equal :runner_not_eligible, result.outcome
    assert_equal "not in scope for this host's principal", result.detail

    runner_b.revoke_credentials
    result = handoff(agent_loop, runner_b.public_id)
    assert_equal :runner_not_eligible, result.outcome
    assert_equal "no ready credential", result.detail

    runner_b.revoke
    result = handoff(agent_loop, runner_b.public_id)
    assert_equal :runner_not_eligible, result.outcome
    assert_equal "revoked", result.detail

    assert_equal runner_a, agent_loop.reload.bound_runner
    assert_equal runner_a.id, node(agent_loop, "r1").addressed_executor_id
    assert_empty items(agent_loop, "runner_bound")
  end

  test "the principal is the host's ANSWERER, never the caller" do
    # A runner private to the OWNER is eligible for a host the owner's agent ANSWERS — a member's
    # conversation included — whoever calls the verb; and not for one answered by an agent stewarded
    # elsewhere, even the owner's own conversation.
    owners_private = connect_runner(manager: @owner, runner_identifier: "owner-private", display_name: "Owner's")
      .executor_access_token.task_executor
    announce!(owners_private, [{ "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                                 "timeout_ms" => READ_TIMEOUT_MS }])
    answered, agent_loop = conversation_on_a(tool("a1"), creating_user: @human, answering_user: @agent)
    assert_equal :accepted, handoff(answered, owners_private.public_id, by: @human).outcome
    assert_equal owners_private.id, node(agent_loop, "a1").addressed_executor_id,
      "the re-addressed row is judged for the answerer too"

    elsewhere = create_agent_member(steward: @human, agent_identifier: "member-agent")
    foreign, = conversation_on_a(tool("f1"), creating_user: @owner, answering_user: elsewhere)
    assert_equal :runner_not_eligible, handoff(foreign, owners_private.public_id, by: @owner).outcome

    # A standalone loop answers as its creator.
    owners_loop = standalone_on_a(tool("o1"), creating_user: @owner)
    assert_equal :accepted, handoff(owners_loop, owners_private.public_id, by: @owner).outcome

    members_loop = standalone_on_a(tool("m1"))
    assert_equal :runner_not_eligible, handoff(members_loop, owners_private.public_id, by: @owner).outcome
  end

  # The binding is HOST-level: a turn addressed to the agent gives the agent no say over the Human's
  # conversation — `caller_may_bind?` admits the host's DEFAULT answerer only, and the target is
  # judged for the host's answerer.
  test "the handoff reads the host's default answerer, never a turn's" do
    runner_a
    plain = Conversation.create!(workspace: @workspace, creating_user: @human, runner_executor: runner_a)
    seam = create_loop_backed_turn(conversation: plain, acting_user: @human, answering_user: @agent)
    grow!(seam.agent_loop, tool("a1"))
    AgentLoops::ScheduleReady.call(agent_loop_id: seam.agent_loop.id)
    clear_enqueued_jobs

    assert_equal :not_authorized, handoff(plain, runner_b.public_id, by: @agent).outcome,
      "the turn's answerer is not the host's"
    assert_equal :accepted, handoff(plain, runner_b.public_id, by: @human).outcome
    assert_equal runner_b.id, node(seam.agent_loop, "a1").addressed_executor_id
  end
end
