require "test_helper"

class WorkspaceCommandReceipt::IdempotentTest < ActiveSupport::TestCase
  # The racing-loser proof needs the simulated winner to commit on a real
  # second connection, which transactional tests would share-lock away.
  uses_transaction :test_a_racing_loser_rolls_back_its_whole_effect_and_settles_on_the_winner,
    :"test_a_refusal_that_raced_a_same-key_winner_settles_on_the_winner's_receipt"

  setup do
    @scope = {
      account: accounts(:cybros), acting_user: users(:member),
      operation: :workspace_create, idempotency_key: "key-1",
      request_digest: WorkspaceCommandReceipt.digest_for(
        operation: :workspace_create, envelope: { "name" => "Fresh" }
      ),
    }
  end

  test "a fresh command runs once and persists its receipt atomically" do
    result = nil
    assert_difference -> { WorkspaceCommandReceipt.count }, +1 do
      result = WorkspaceCommandReceipt::Idempotent.call(**@scope) do
        created = Workspaces::Create.call(creator: users(:member), name: "Fresh").workspace
        WorkspaceCommandReceipt::Idempotent::Success.new(
          status: 201, body: { "workspace" => { "public_id" => created.public_id } },
          workspace: created
        )
      end
    end

    assert_equal :executed, result.outcome
    assert_equal 201, result.response.status
    receipt = WorkspaceCommandReceipt.sole
    assert_equal 201, receipt.response_status
    assert_equal "workspace_create", receipt.operation
    assert_equal result.response.workspace.id, receipt.workspace_id
  end

  test "an exact replay returns the stored response without running the command" do
    first = WorkspaceCommandReceipt::Idempotent.call(**@scope) do
      created = Workspaces::Create.call(creator: users(:member), name: "Fresh").workspace
      WorkspaceCommandReceipt::Idempotent::Success.new(
        status: 201, body: { "workspace" => { "public_id" => created.public_id } },
        workspace: created
      )
    end
    assert_equal :executed, first.outcome

    ran = false
    replay = assert_no_difference -> { Workspace.count } do
      WorkspaceCommandReceipt::Idempotent.call(**@scope) do
        ran = true
        flunk "the command must not run on replay"
      end
    end

    assert_not ran
    assert_equal :replayed, replay.outcome
    assert_equal 201, replay.receipt.response_status
    assert_equal first.response.body, replay.receipt.response_body
  end

  test "the same key with a different digest is a mismatch" do
    WorkspaceCommandReceipt::Idempotent.call(**@scope) do
      created = Workspaces::Create.call(creator: users(:member), name: "Fresh").workspace
      WorkspaceCommandReceipt::Idempotent::Success.new(status: 201, body: {}, workspace: created)
    end

    mismatch = WorkspaceCommandReceipt::Idempotent.call(
      **@scope, request_digest: WorkspaceCommandReceipt.digest_for(
        operation: :workspace_create, envelope: { "name" => "Different" }
      )
    ) do
      flunk "the command must not run on mismatch"
    end

    assert_equal :mismatched, mismatch.outcome
  end

  test "a domain refusal writes no receipt and surfaces the refusal" do
    refusal = Workspaces::Mutation::Result.blocked(:not_authorized)

    result = assert_no_difference -> { WorkspaceCommandReceipt.count } do
      WorkspaceCommandReceipt::Idempotent.call(**@scope) { refusal }
    end

    assert_equal :refused, result.outcome
    assert_equal refusal, result.refusal
  end

  test "an expired receipt stops reserving the key and is taken over" do
    stale = WorkspaceCommandReceipt.create!(
      account: accounts(:cybros), workspace: workspaces(:shared), acting_user: users(:member),
      operation: :workspace_create, idempotency_key: "key-1",
      request_digest: "f" * 64, response_status: 201, response_body: {},
    )
    stale.update_columns(created_at: 25.hours.ago)

    result = nil
    assert_no_difference -> { WorkspaceCommandReceipt.count } do
      result = WorkspaceCommandReceipt::Idempotent.call(**@scope) do
        created = Workspaces::Create.call(creator: users(:member), name: "Fresh").workspace
        WorkspaceCommandReceipt::Idempotent::Success.new(status: 201, body: {}, workspace: created)
      end
    end

    assert_equal :executed, result.outcome
    assert_nil WorkspaceCommandReceipt.find_by(id: stale.id)
  end

  test "a racing loser rolls back its whole effect and settles on the winner" do
    scope = @scope
    winner_body = { "workspace" => { "public_id" => "winner" } }
    winner_attributes = {
      account_id: accounts(:cybros).id, workspace_id: workspaces(:shared).id,
      acting_user_id: users(:member).id, operation: "workspace_create",
      idempotency_key: "key-1", request_digest: scope[:request_digest],
      response_status: 201, response_body: winner_body,
    }

    result = WorkspaceCommandReceipt::Idempotent.call(**scope) do
      # The concurrent winner commits on its own connection between this
      # call's lookup and its own receipt insert.
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          WorkspaceCommandReceipt.create!(winner_attributes)
        end
      end.join

      created = Workspaces::Create.call(creator: users(:member), name: "Loser").workspace
      WorkspaceCommandReceipt::Idempotent::Success.new(status: 201, body: {}, workspace: created)
    end

    assert_equal :replayed, result.outcome
    assert_equal winner_body, result.receipt.response_body
    # The loser's whole effect rolled back with its transaction.
    assert_equal 0, Workspace.where(name: "Loser").count
  ensure
    WorkspaceCommandReceipt.where(idempotency_key: "key-1").delete_all
  end

  test "a refusal that raced a same-key winner settles on the winner's receipt" do
    scope = @scope
    winner_body = { "workspace" => { "public_id" => "winner" } }
    winner_attributes = {
      account_id: accounts(:cybros).id, workspace_id: workspaces(:shared).id,
      acting_user_id: users(:member).id, operation: "workspace_create",
      idempotency_key: "key-1", request_digest: scope[:request_digest],
      response_status: 201, response_body: winner_body,
    }

    result = WorkspaceCommandReceipt::Idempotent.call(**scope) do
      # The winner commits while this command is blocked on domain locks;
      # its effect then surfaces as a domain refusal (the key_taken shape).
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          WorkspaceCommandReceipt.create!(winner_attributes)
        end
      end.join

      Workspaces::Mutation::Result.blocked(:key_taken)
    end

    assert_equal :replayed, result.outcome
    assert_equal winner_body, result.receipt.response_body
  ensure
    WorkspaceCommandReceipt.where(idempotency_key: "key-1").delete_all
  end

  test "store entry receipts scope by parent workspace" do
    entry_scope = {
      account: accounts(:cybros), acting_user: users(:member),
      operation: :store_entry_create, idempotency_key: "entry-key",
      request_digest: "a" * 64, workspace: workspaces(:shared),
    }
    first = WorkspaceCommandReceipt::Idempotent.call(**entry_scope) do
      WorkspaceCommandReceipt::Idempotent::Success.new(
        status: 201, body: {}, workspace: workspaces(:shared)
      )
    end
    assert_equal :executed, first.outcome

    # The same key under a different parent is an independent command.
    other_parent = WorkspaceCommandReceipt::Idempotent.call(
      **entry_scope, workspace: workspaces(:personal)
    ) do
      WorkspaceCommandReceipt::Idempotent::Success.new(
        status: 201, body: {}, workspace: workspaces(:personal)
      )
    end
    assert_equal :executed, other_parent.outcome

    replay = WorkspaceCommandReceipt::Idempotent.call(**entry_scope) do
      flunk "the command must not run on replay"
    end
    assert_equal :replayed, replay.outcome
  end
end
