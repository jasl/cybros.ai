require "test_helper"

class Executors::DefaultRunnerTest < ActiveJob::TestCase
  include InvocationHarness
  include RunSeamTestHelper

  READ_TIMEOUT_MS = 90_000

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read", **over)
    super(key, name, "input" => { "path" => key }, "route" => { "kind" => "runner" }, **over)
  end

  def runner_a = suite_runner

  def runner_b
    @runner_b ||= connect_runner(manager: @owner, registration_identifier: "runner-b",
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

  def standalone_on_a(*steps, creating_user: @human)
    agent_run = seed(*steps, creating_user: creating_user, default_runner_executor_public_id: runner_a.public_id)
    start!(agent_run, acting_user: creating_user)
    agent_run
  end

  def start!(agent_run, acting_user: @human)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: acting_user))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def conversation_on_a(*steps, creating_user: @human, answering_user: creating_user, workspace: @workspace)
    conversation = Conversation.create!(workspace: workspace, creating_user: creating_user,
      answering_user: answering_user, default_runner_executor: runner_a)
    seam = create_run_backed_turn(conversation: conversation, acting_user: creating_user)
    grow!(seam.agent_run, *steps) if steps.any?
    AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    clear_enqueued_jobs
    [conversation, seam.agent_run]
  end

  def selection(host, executor_public_id, by: @human)
    Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: host, executor_public_id: executor_public_id, acting_user: by
    ))
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def items(host, type)
    host.conversation_event_items.where(item_type: type).order(:sequence).map(&:payload)
  end

  test "changing the default preserves a dispatched target and its clock" do
    run = standalone_on_a(tool("read-a"))
    task = node(run, "read-a")
    before = task.attributes.slice("target_executor_id", "target_executor_public_id", "addressed_executor_id",
      "effect_profile", "await_started_at", "claim_token")
    travel 5.seconds

    assert_predicate selection(run, runner_b.public_id), :accepted?

    assert_equal before, task.reload.attributes.slice(*before.keys)
    assert_equal runner_b, run.reload.default_runner
    assert_equal runner_b.public_id, items(run, "default_runner_changed").sole.fetch("executor_public_id")
  end

  test "queued work freezes default A before a later change to B" do
    run = seed(tool("read-a"), default_runner_executor_public_id: runner_a.public_id)
    assert_equal runner_a.public_id, node(run, "read-a").target_executor_public_id
    selection(run, runner_b.public_id)
    start!(run)
    assert_equal runner_a.id, node(run, "read-a").addressed_executor_id
  end

  test "clearing the default preserves accepted targets and refuses new unqualified Runner work" do
    run = seed(tool("read-a"), default_runner_executor_public_id: runner_a.public_id)
    assert_predicate selection(run, nil), :accepted?
    assert_nil run.reload.default_runner
    assert_nil items(run, "default_runner_changed").sole.fetch("executor_public_id")
    assert_equal :runner_target_required, grow(run, tool("read-next")).outcome
    start!(run)
    assert_equal runner_a.id, node(run, "read-a").addressed_executor_id
  end

  test "selecting the same default is idempotent by value" do
    run = seed(tool("read-a"), default_runner_executor_public_id: runner_a.public_id)
    assert_predicate selection(run, runner_a.public_id), :accepted?
    assert_empty items(run, "default_runner_changed")
  end

  test "a fork after a selection copies the new binding" do
    runner_a
    runner_b
    actor = Speakers::Resolve.member(account: @account, user: @human)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: runner_a)
    turn = ConversationTurn.create!(account: @account, conversation: conversation, position: 0,
      kind: "message", role: "user", status: "completed", speaker: actor, control_owner_user: @human)
    variant = ConversationTurnVariant.create!(account: @account, conversation_turn: turn, position: 0,
      status: "completed", source: "inference", content_preview: "hi")
    ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => "hi" }], seal: true)
    turn.update!(active_variant: variant)
    conversation.update!(timeline_position_head: 1)

    selection(conversation, runner_b.public_id)
    forked = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: conversation, turn_public_id: turn.public_id, variant_public_id: nil,
      acting_user: @human, title: nil
    ))

    assert_equal :accepted, forked.outcome
    assert_equal runner_b.id, forked.value.default_runner_executor_id
  end

  # --- the caller rule ---------------------------------------------

  test "the host's ANSWERER on its own bearer binds; another agent is not_authorized" do
    conversation, agent_run = conversation_on_a(tool("r1"), creating_user: @agent)
    other_agent = create_agent_member(steward: @owner, agent_identifier: "other-agent")

    refused = selection(conversation, runner_b.public_id, by: other_agent)
    assert_equal :not_authorized, refused.outcome
    assert_equal runner_a, conversation.reload.default_runner

    bound = selection(conversation, runner_b.public_id, by: @agent)
    assert_equal :accepted, bound.outcome
    assert_equal runner_a.id, node(agent_run, "r1").addressed_executor_id
    assert_equal @agent.public_id, items(conversation, "default_runner_changed").sole.fetch("by")

    # A Human's conversation the agent ANSWERS: the answerer binds, the creator's kind
    # notwithstanding; any other agent has no say.
    answered, = conversation_on_a(tool("a1"), creating_user: @human, answering_user: @agent)
    assert_equal :not_authorized, selection(answered, runner_b.public_id, by: other_agent).outcome
    assert_equal :accepted, selection(answered, runner_b.public_id, by: @agent).outcome
  end

  test "a Human with write standing binds an agent's host; a Human without has no standing" do
    conversation, = conversation_on_a(tool("r1"), creating_user: @agent)

    assert_equal :accepted, selection(conversation, runner_b.public_id, by: @owner).outcome

    private_host = Conversation.create!(workspace: workspaces(:personal), creating_user: users(:curator),
      default_runner_executor: runner_a)
    refused = selection(private_host, runner_b.public_id, by: @human)
    assert_equal :not_authorized, refused.outcome
    assert_equal runner_a, private_host.reload.default_runner
  end

  # --- the target rule ---------------------------------------------

  # The fifth door the design missed: the selection is a write on the host, so a Human the
  # conversation lists at `read` has no standing to bind — whatever the workspace says — while the
  # answerer stays full by derivation and binds on its own bearer.
  test "a Human the conversation lists at read cannot bind, workspace write standing notwithstanding" do
    conversation, = conversation_on_a(tool("r1"), creating_user: @agent)
    conversation.conversation_access_entries.create!(user: @owner, level: "read")

    refused = selection(conversation, runner_b.public_id, by: @owner)
    assert_equal :not_authorized, refused.outcome
    assert_equal runner_a, conversation.reload.default_runner
    assert_empty items(conversation, "default_runner_changed")

    assert_equal :accepted, selection(conversation, runner_b.public_id, by: @agent).outcome
  end

  test "an unknown id, a tools provider and an agent address are runner_not_found" do
    agent_run = standalone_on_a(tool("r1"))
    provider = connect_provider(identifier: "pool-p", tools: ["read"])

    assert_equal :runner_not_found, selection(agent_run, SecureRandom.uuid_v7).outcome
    assert_equal :runner_not_found, selection(agent_run, provider.public_id).outcome
    assert_equal :runner_not_found, selection(agent_run, task_executors(:address).public_id).outcome
    assert_equal runner_a, agent_run.reload.default_runner
    assert_empty items(agent_run, "default_runner_changed")
  end

  test "an ineligible runner is runner_not_eligible naming the reason, and nothing moves" do
    agent_run = standalone_on_a(tool("r1"))

    scoped = connect_runner(manager: @human, registration_identifier: "member-private", display_name: "Private")
      .executor_access_token.task_executor
    owners_loop = standalone_on_a(tool("o1"), creating_user: @owner)
    result = selection(owners_loop, scoped.public_id, by: @owner)
    assert_equal :runner_not_eligible, result.outcome
    assert_equal "not in scope for this host's principal", result.detail

    runner_b.revoke_credentials
    result = selection(agent_run, runner_b.public_id)
    assert_equal :runner_not_eligible, result.outcome
    assert_equal "no ready credential", result.detail

    runner_b.revoke
    result = selection(agent_run, runner_b.public_id)
    assert_equal :runner_not_eligible, result.outcome
    assert_equal "revoked", result.detail

    assert_equal runner_a, agent_run.reload.default_runner
    assert_equal runner_a.id, node(agent_run, "r1").addressed_executor_id
    assert_empty items(agent_run, "default_runner_changed")
  end

  test "the principal is the host's ANSWERER, never the caller" do
    # A runner private to the OWNER is eligible for a host the owner's agent ANSWERS — a member's
    # conversation included — whoever calls the verb; and not for one answered by an agent stewarded
    # elsewhere, even the owner's own conversation.
    owners_private = connect_runner(manager: @owner, registration_identifier: "owner-private", display_name: "Owner's")
      .executor_access_token.task_executor
    announce!(owners_private, [{ "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                                 "timeout_ms" => READ_TIMEOUT_MS }])
    answered, agent_run = conversation_on_a(tool("a1"), creating_user: @human, answering_user: @agent)
    assert_equal :accepted, selection(answered, owners_private.public_id, by: @human).outcome
    assert_equal runner_a.id, node(agent_run, "a1").addressed_executor_id

    elsewhere = create_agent_member(steward: @human, agent_identifier: "member-agent")
    foreign, = conversation_on_a(tool("f1"), creating_user: @owner, answering_user: elsewhere)
    assert_equal :runner_not_eligible, selection(foreign, owners_private.public_id, by: @owner).outcome

    # A standalone loop answers as its creator.
    owners_loop = standalone_on_a(tool("o1"), creating_user: @owner)
    assert_equal :accepted, selection(owners_loop, owners_private.public_id, by: @owner).outcome

    members_loop = standalone_on_a(tool("m1"))
    assert_equal :runner_not_eligible, selection(members_loop, owners_private.public_id, by: @owner).outcome
  end

  # The binding is HOST-level: a turn addressed to the agent gives the agent no say over the Human's
  # conversation — `caller_may_bind?` admits the host's DEFAULT answerer only, and the target is
  # judged for the host's answerer.
  test "the selection reads the host's default answerer, never a turn's" do
    runner_a
    plain = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: runner_a)
    seam = create_run_backed_turn(conversation: plain, acting_user: @human, answering_user: @agent)
    grow!(seam.agent_run, tool("a1"))
    AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    clear_enqueued_jobs

    assert_equal :not_authorized, selection(plain, runner_b.public_id, by: @agent).outcome,
      "the turn's answerer is not the host's"
    assert_equal :accepted, selection(plain, runner_b.public_id, by: @human).outcome
    assert_equal runner_a.id, node(seam.agent_run, "a1").addressed_executor_id
  end
end
