require "test_helper"

# The aggregate-root create and its receipt idempotency — deliberately
# small: no actor setup, no event narration, no parent linkage (subagent
# spawn is the AgentRun round's kernel-driven create).
class Conversations::CreateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
  end

  def command(**overrides)
    Conversations::Create::Command.new(**{
      workspace: @workspace, creating_user: @user,
      title: "  Field notes  ", metadata: { "k" => "v" }, billing_subject: nil,
    }.merge(overrides))
  end

  test "a conversation is created with a trimmed title and its metadata" do
    result = Conversations::Create.call(command)

    assert_predicate result, :accepted?
    conversation = result.value
    assert_equal "Field notes", conversation.title
    assert_equal({ "k" => "v" }, conversation.metadata)
    assert_nil conversation.billing_subject_key
    assert_equal @workspace.id, conversation.workspace_id
  end

  test "a blank title stores as nil and absent metadata as an empty bag" do
    result = Conversations::Create.call(command(title: "   ", metadata: nil))

    assert_predicate result, :accepted?
    assert_nil result.value.title
    assert_equal({}, result.value.metadata)
  end

  test "a billing subject is verified and its frozen pair copied" do
    result = Conversations::Create.call(command(billing_subject: "team-alpha"))

    assert_predicate result, :accepted?
    subject = BillingSubject.find_by!(account: @account, key: "team-alpha")
    assert_equal subject.key, result.value.billing_subject_key
    assert_equal subject.public_id, result.value.billing_subject_public_id
  end

  test "another owner's billing key refuses without a row" do
    BillingSubject.create!(account: @account, owning_user: users(:owner), key: "team-b")

    result = Conversations::Create.call(command(billing_subject: "team-b"))

    assert_equal :billing_subject_not_owned, result.outcome
    assert_equal 0, Conversation.count
  end

  test "an unreachable workspace admits nothing" do
    result = Conversations::Create.call(command(workspace: workspaces(:personal)))

    assert_equal :not_authorized, result.outcome
    assert_equal 0, Conversation.count
  end

  test "an overlong title is a validation refusal, not a database error" do
    result = Conversations::Create.call(command(title: "t" * 256))

    assert_equal :invalid, result.outcome
    assert result.record.errors.of_kind?(:title, :too_long)
  end

  # ── the answering profile ─────────────────────────────────

  # Omitted, the creator answers its own conversation; named, the id must
  # be an agent profile of the account that may write in this workspace —
  # anything else, absence included, is ONE refusal `answerer_not_eligible`.
  test "the answerer is named at create, or is the creator; the ineligible are refused as one" do
    assert_equal @user, Conversations::Create.call(command).value.answering_user, "omitted: the creator, a Human"
    assert_equal users(:agent), Conversations::Create.call(command(creating_user: users(:agent))).value.answering_user,
      "omitted: the creator, an agent"

    named = Conversations::Create.call(command(answering_user_public_id: users(:agent).public_id))
    assert_predicate named, :accepted?
    assert_equal users(:agent), named.value.answering_user, "a Human's conversation, an agent's engine"
    assert_equal @user, named.value.creating_user

    removed = create_agent_member(agent_identifier: "removed-agent")
    assert_equal :removed, removed.remove
    fenced = create_agent_member(agent_identifier: "fenced-agent")
    Workspace.where(id: @workspace.id).update_all(agent_identifier: users(:agent).agent_identifier)
    @workspace.reload
    {
      "a Human" => users(:owner).public_id,
      "oneself" => @user.public_id,
      "an unknown id" => SecureRandom.uuid_v7,
      "the system user" => users(:system).public_id,
      "a removed profile" => removed.public_id,
      "a profile the dedication fence refuses" => fenced.public_id,
    }.each do |label, public_id|
      result = Conversations::Create.call(command(answering_user_public_id: public_id))
      assert_equal :answerer_not_eligible, result.outcome, label
    end
    assert_equal 3, Conversation.count, "the refusals left no row"
  end

  # The runner is judged for the ANSWERER: a runner private to the answerer's steward binds when the
  # creator is another Human with write standing, and the answerer is resolved before the runner is.
  test "the named runner is judged for the answerer, never the creator" do
    private_runner = connect_runner(manager: users(:owner), registration_identifier: "private-1",
      assignment_scope: :user_private).executor_access_token.task_executor

    refused = Conversations::Create.call(command(default_runner_executor_public_id: private_runner.public_id))
    assert_equal :runner_not_eligible, refused.outcome, "for the creator alone, the owner's runner is out of scope"

    result = Conversations::Create.call(command(
      default_runner_executor_public_id: private_runner.public_id, answering_user_public_id: users(:agent).public_id
    ))
    assert_predicate result, :accepted?
    assert_equal private_runner, result.value.default_runner_executor
    assert_equal users(:agent), result.value.answering_user

    ineligible = Conversations::Create.call(command(
      default_runner_executor_public_id: private_runner.public_id, answering_user_public_id: users(:owner).public_id
    ))
    assert_equal :answerer_not_eligible, ineligible.outcome, "the answerer is judged first"
  end

  # ── the initial runner binding ──────────────────────────────

  def connect_wide_runner(identifier)
    connect_runner(
      manager: users(:owner), registration_identifier: identifier, assignment_scope: :account_wide
    ).executor_access_token.task_executor
  end

  test "an agent creator's announced address is never the binding; the named runner is" do
    address = task_executors(:address)
    address.announce(tools: [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])
    wide = connect_wide_runner("wide-1")

    unnamed = Conversations::Create.call(command(creating_user: users(:agent)))
    assert_predicate unnamed, :accepted?
    assert_nil unnamed.value.default_runner_executor, "unnamed is unbound: the address is no binding, the runner is not inferred"

    result = Conversations::Create.call(command(creating_user: users(:agent), default_runner_executor_public_id: wide.public_id))

    assert_predicate result, :accepted?
    assert_equal wide, result.value.default_runner_executor, "the runner-kind ROW the creator named"
    assert_equal wide, result.value.default_runner
  end

  test "a creator that names a runner binds it over two eligible" do
    connect_wide_runner("wide-1")
    wide2 = connect_wide_runner("wide-2")

    result = Conversations::Create.call(command(default_runner_executor_public_id: wide2.public_id))

    assert_predicate result, :accepted?
    assert_equal wide2, result.value.default_runner_executor
  end

  test "an ineligible request is refused runner_not_eligible" do
    connect_wide_runner("wide-1")
    private_runner = connect_runner(manager: users(:owner), registration_identifier: "private-1",
      assignment_scope: :user_private).executor_access_token.task_executor

    result = Conversations::Create.call(command(default_runner_executor_public_id: private_runner.public_id))

    assert_equal :runner_not_eligible, result.outcome
    assert_equal 0, Conversation.count
  end

  # r-modes M6: the kernel infers no runner — an unnamed create is unbound
  # whether none, one or two runners are eligible for the creator.
  test "an unnamed create binds nothing, whatever is eligible" do
    assert_nil Conversations::Create.call(command).value.default_runner_executor

    connect_wide_runner("wide-1")
    assert_nil Conversations::Create.call(command).value.default_runner_executor,
      "one eligible runner is not inferred"

    connect_wide_runner("wide-2")
    assert_nil Conversations::Create.call(command).value.default_runner_executor,
      "nothing selects an execution host on its own"
  end

  # ── the receipt wrapper ────────────────────────────────────────────────

  def idempotent(key:, digest:, &block)
    ConversationCommandReceipt::Idempotent.call(
      account: @account, workspace: @workspace, acting_user: @user,
      operation: "conversation_create", idempotency_key: key,
      request_digest: digest, &block
    )
  end

  def run_create(key:, digest:)
    idempotent(key: key, digest: digest) do
      result = Conversations::Create.call(command)
      if result.accepted?
        ConversationCommandReceipt::Idempotent::Success.new(
          status: 201,
          body: { "public_id" => result.value.public_id },
          host: result.value
        )
      else
        result
      end
    end
  end

  test "the receipt commits atomically with its effect and replays verbatim" do
    digest = SecureRandom.hex(32)
    first = run_create(key: "k-1", digest: digest)

    assert_equal :executed, first.outcome
    assert_equal 1, ConversationCommandReceipt.count

    replay = run_create(key: "k-1", digest: digest)
    assert_equal :replayed, replay.outcome
    assert_equal first.response.body, replay.receipt.response_body
    assert_equal 1, Conversation.count, "a replay never creates a second row"
  end

  test "the same key with a different envelope is a mismatch, never a second effect" do
    run_create(key: "k-2", digest: "a" * 64)

    result = run_create(key: "k-2", digest: "b" * 64)

    assert_equal :mismatched, result.outcome
    assert_equal 1, Conversation.count
  end

  test "a refusal leaves no receipt, so a corrected retry may succeed" do
    digest = SecureRandom.hex(32)
    refused = idempotent(key: "k-3", digest: digest) do
      Conversations::Create.call(command(workspace: workspaces(:personal)))
    end

    assert_equal :refused, refused.outcome
    assert_equal 0, ConversationCommandReceipt.count

    retried = run_create(key: "k-3", digest: digest)
    assert_equal :executed, retried.outcome
  end

  test "the conversation-anchored operations refuse to run without their conversation" do
    assert_raises(ArgumentError) do
      ConversationCommandReceipt::Idempotent.call(
        account: @account, workspace: @workspace, acting_user: @user,
        operation: "fork", idempotency_key: "k", request_digest: "c" * 64
      ) { nil }
    end
  end

  # ── the parent arm ────────────────────────────────────────

  # A SPAWNED child hangs off the parent conversation and names the call that minted it; it copies
  # the parent's access carrier (the fork rule: entries plus the parent's derived-full pair
  # materialized, minus the child's own derived pair), the parent's billing pair verbatim, and the
  # parent's runner when it is eligible for the child's ANSWERER — else nothing, never a refusal. A
  # side never spawns. One loop-backed turn per parent; each spawn call is its own node under it (a
  # message may spawn several times).
  def spawn_node_for(parent)
    @seams ||= {}
    seam = @seams[parent.id] ||= create_run_backed_turn(conversation: parent, acting_user: @user)
    key = "r1t#{seam.agent_run.agent_run_tasks.where("node_key LIKE 'r1t%'").count}"
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: seam.agent_run, origin: "model",
      steps: [AgentRuns::Tasks::Step::Tool.new(key: key, name: "spawn", input: { "prompt" => "go" })],
      tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH)
    ))
    assert_predicate appended, :applied?, appended.outcome.to_s
    seam.agent_run.agent_run_tasks.find_by!(node_key: key)
  end

  def spawn_command(parent, **overrides)
    command(creating_user: users(:agent), parent: parent, spawn_node: spawn_node_for(parent), title: nil,
      metadata: nil, **overrides)
  end

  test "a spawned child hangs off the parent, names its spawn call, and copies the carrier, billing and runner" do
    subject = BillingSubject.create!(account: @account, owning_user: @user, key: "team-a")
    wide = connect_wide_runner("wide-1")
    reader = users(:curator)
    parent = Conversations::Create.call(command(
      answering_user_public_id: users(:agent).public_id, billing_subject: subject.key,
      default_runner_executor_public_id: wide.public_id,
      access: { "default" => "read", "entries" => [{ "user_public_id" => reader.public_id, "level" => "full" }] }
    )).value

    result = Conversations::Create.call(spawn_command(parent, spawn_label: " Reviewer ",
      default_runner_executor_public_id: wide.public_id))

    assert_predicate result, :accepted?, result.outcome.to_s
    child = result.value
    assert_equal [parent.id, parent.public_id], [child.parent_conversation_id, child.parent_conversation_public_id]
    assert_equal parent.hosted_agent_runs.sole.agent_run_tasks.find_by!(node_key: "r1t0"), child.spawn_node
    assert_equal "reviewer", child.spawn_label, "normalized: stripped, lowercased"
    assert_equal [users(:agent), users(:agent)], [child.creating_user, child.answering_user]
    assert_equal "read", child.access_default, "the parent's default"
    assert_equal({ reader.id => "full", @user.id => "full" }, child.conversation_access_entries.pluck(:user_id, :level).to_h,
      "the parent's entries plus its derived-full creator; the parent's answerer is the child's own pair")
    assert_equal [subject.key, subject.public_id], [child.billing_subject_key, child.billing_subject_public_id]
    assert_equal wide, child.default_runner_executor
    assert_not_nil child.conversation_event_cursor, "born with its cursor"
  end

  test "a spawned child's selected Runner must be eligible and explicit null clears that choice" do
    private_runner = connect_runner(manager: users(:owner), registration_identifier: "private-1",
      assignment_scope: :user_private).executor_access_token.task_executor
    parent = Conversation.create!(workspace: @workspace, creating_user: users(:owner), answering_user: users(:agent),
      default_runner_executor: private_runner)
    peer = create_agent_member(display_name: "Peer", agent_identifier: "peer-1", steward: @user)

    refused = Conversations::Create.call(spawn_command(parent, answering_user_public_id: peer.public_id,
      default_runner_executor_public_id: private_runner.public_id))
    assert_equal :runner_not_eligible, refused.outcome

    result = Conversations::Create.call(spawn_command(parent, answering_user_public_id: peer.public_id,
      default_runner_executor_public_id: nil))

    assert_predicate result, :accepted?, result.outcome.to_s
    assert_nil result.value.default_runner_executor, "the caller explicitly selected no default"
    assert_equal peer, result.value.answering_user
    assert_equal({ users(:owner).id => "full" },
      result.value.conversation_access_entries.pluck(:user_id, :level).to_h,
      "the parent's derived creator materialized; its answerer is the SPAWNER — the child's own creator, " \
      "derived, never a row — and the peer is the child's answerer")
  end

  test "a spawned child's label is refused when malformed or taken under the same parent" do
    parent = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent))
    assert_predicate Conversations::Create.call(spawn_command(parent, spawn_label: "reviewer")), :accepted?

    taken = Conversations::Create.call(spawn_command(parent, spawn_label: "REVIEWER"))
    assert_equal :invalid, taken.outcome
    assert taken.record.errors.of_kind?(:spawn_label, :taken)

    malformed = Conversations::Create.call(spawn_command(parent, spawn_label: "Not a label!"))
    assert_equal :invalid, malformed.outcome
    assert malformed.record.errors.of_kind?(:spawn_label, :invalid)

    other = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent))
    assert_predicate Conversations::Create.call(spawn_command(other, spawn_label: "reviewer")), :accepted?,
      "unique among ONE parent's children"
  end

  test "a side conversation never spawns" do
    side = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent), side: true)

    result = Conversations::Create.call(spawn_command(side))

    assert_equal :side_conversation, result.outcome
    assert_equal 1, Conversation.count
  end
end
