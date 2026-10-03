require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class WorkspacesLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "workspace transfer locks the workspace before both humans" do
    personal = workspaces(:personal)

    sequences = assert_ladder_order("workspace transfer") do
      result = Workspaces::TransferOwnership.call(
        workspace: personal, by: users(:curator), to: users(:owner),
        lock_version: personal.lock_version
      )
      assert_equal :transferred, result.outcome
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "workspaces"
    assert_includes seen, "users"
  end

  test "owner-authorized workspace update locks the workspace before the actor" do
    personal = workspaces(:personal)

    sequences = assert_ladder_order("workspace update") do
      result = Workspaces::Update.call(
        workspace: personal, by: users(:curator),
        lock_version: personal.lock_version, name: "Guarded"
      )
      assert_equal :updated, result.outcome
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "workspaces"
    assert_includes seen, "users"
  end

  # The override PUT takes the workspace row ALONE: the provider checks are lock-free reads
  # (`task_executors` ranks above the host rungs and is never locked here), and the standing ladder
  # locks no user row.
  test "the override PUT takes the workspace row alone" do
    shared = workspaces(:shared)
    provider = connect_provider(identifier: "guard-mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))

    sequences = assert_ladder_order("override PUT") do
      result = Workspaces::SetToolProviderOverrides.call(
        workspace: shared, by: users(:owner), lock_version: shared.lock_version,
        overrides: { "nexus.memory" => provider.public_id }
      )
      assert_equal :updated, result.outcome
    end

    assert_equal ["workspaces"], sequences.flatten.uniq
  end

  test "agent workspace create locks the agent then its steward" do
    agent = create_agent_member(steward: users(:member), agent_identifier: "install-guard-workspace")

    sequences = assert_ladder_order("agent workspace create") do
      result = Workspaces::Create.call(creator: agent, name: "Guard Scratch")
      assert_equal :created, result.outcome
    end

    assert_includes sequences.flatten.uniq, "users"
  end

  test "lifecycle acceptance and completion keep the workspace-first order" do
    personal = workspaces(:personal)
    _, invocation = create_invocation(
      account: accounts(:cybros), workspace: personal, creator: users(:curator)
    )

    sequences = assert_ladder_order("archive acceptance") do
      result = Workspaces::Archive.call(
        workspace: personal, by: users(:curator), lock_version: personal.lock_version
      )
      assert_equal :accepted, result.outcome
    end
    seen = sequences.flatten.uniq
    assert_includes seen, "workspaces"
    assert_predicate invocation.reload, :canceled?

    completion = assert_ladder_order("transition completion") do
      assert_equal :completed, Workspaces::CompleteTransition.call(workspace: personal).outcome
    end
    assert_includes completion.flatten.uniq, "workspaces"
  end

  # Collection's drain claims the OneShot owner before taking the sorted
  # Upload locks used by count reconciliation.
  #
  # THE DRAIN'S DELETES TAKE ROW LOCKS THIS GUARD CANNOT SEE — it reads
  # explicit locking SELECTs, and a DELETE takes its lock without one. So the
  # drain takes its invocation locks explicitly, in ladder order, before
  # deleting bottom-up underneath them, and that locking SELECT is what the
  # assertion below reads.
  #
  # It is not decoration. The FK order and the ladder order are opposite here
  # (attempts must be DELETED first, invocations must be LOCKED first), and
  # `ConvergePostCut#converge` and `DeadlineSweep#settle` both take exactly
  # these two rows the other way, every minute. An earlier version of this
  # comment asserted no other writer could reach them; that was false, and
  # the ABBA it hid was reachable through both reclamation gates, which test
  # only `ModelInvocation.nonterminal`.
  test "workspace collection drains without acquiring against the ladder" do
    account = accounts(:cybros)
    workspace = account.workspaces.create!(
      creator: users(:member), owner: users(:member), name: "Guard collect"
    )
    one_shot, invocation = create_invocation(account: account, workspace: workspace)
    source = ContentBodies::Replace.call(
      owner: one_shot, role: "input", entries: [{ "text" => "guard-collect" }],
      uploads: [create_content_upload(account: account)], seal: true
    ).body
    ContentBodies::CloneSealed.call(source: source, owner: invocation, role: "request")
    # ADMITTED, so the aggregate really owns an Attempt. Draining one that
    # never ran exercises none of the order this test is about — which is how
    # both the RESTRICT violation and the ABBA above reached main.
    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length
    ModelInvocation.where(id: invocation.id).update_all(
      status: "completed", terminal_at: Time.current
    )
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    sequences = assert_ladder_order("workspace collection") do
      assert_operator Workspaces::Collect.call(budget: 50)[:processed], :>, 0
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "one_shots"
    assert_not_includes seen, "content_uploads"
    assert_includes seen, "model_invocations",
      "the drain must take its invocation locks explicitly, or its DELETE order is invisible " \
      "to this guard and free to descend the ladder backwards"
    assert_not ModelInvocation.exists?(invocation.id)
  end
end
