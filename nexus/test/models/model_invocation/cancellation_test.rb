require "test_helper"

# Authority cancellation is one guarded set update. The owner transaction
# supplies the authority fence; this writer changes only current Invocation
# truth and leaves Attempt/event convergence to their recurring owners.
class ModelInvocation::CancellationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
  end

  test "a cut stops exactly the nonterminal scope with one update" do
    queued = create_aggregate
    running = create_aggregate
    running.update!(status: "running")
    completed = create_aggregate
    completed.update!(status: "completed", terminal_at: 1.hour.ago)
    elsewhere = create_aggregate(workspace: workspaces(:personal))
    statements = capture_invocation_sql do
      assert_equal 2, cancel(ModelInvocation.where(workspace_id: @workspace.id))
    end

    assert_equal 1, statements.length
    sql = statements.sole
    assert sql.start_with?('UPDATE "model_invocations"')
    assert_includes sql, '"model_invocations"."workspace_id"'
    assert_includes sql, '"model_invocations"."status" IN'
    assert_no_match(/WITH |LIMIT |FOR UPDATE/, sql)

    [queued, running].each do |invocation|
      invocation.reload
      assert_predicate invocation, :canceled?
      assert_equal "workspace_archived", invocation.cancellation_reason
      assert_not_nil invocation.canceled_at
      assert_not_nil invocation.terminal_at
    end
    assert_predicate completed.reload, :completed?
    assert_predicate elsewhere.reload, :queued?
  end

  test "the first terminal winner is never rewritten" do
    invocation = create_aggregate
    cancel(ModelInvocation.where(id: invocation.id), reason: "workspace_archived")
    first = invocation.reload.slice(
      :status, :cancellation_reason, :canceled_at, :terminal_at, :updated_at
    )

    assert_equal 0,
      cancel(ModelInvocation.where(id: invocation.id), reason: "workspace_deleted")
    assert_equal first, invocation.reload.slice(
      :status, :cancellation_reason, :canceled_at, :terminal_at, :updated_at
    )
  end

  test "generation evidence stays with its owning cut" do
    direct = create_aggregate
    cancel(
      ModelInvocation.where(id: direct.id), reason: "user_removed",
      source_user_authority_generation: 7
    )

    direct.reload
    assert_equal 7, direct.source_user_authority_generation
    assert_nil direct.steward_shutdown_generation

    stewarded = create_aggregate
    cancel(
      ModelInvocation.where(id: stewarded.id), reason: "steward_removed",
      steward_shutdown_generation: 3
    )

    stewarded.reload
    assert_equal 3, stewarded.steward_shutdown_generation
    assert_nil stewarded.source_user_authority_generation
  end

  test "an unknown reason is rejected before the update" do
    invocation = create_aggregate

    error = assert_raises(ArgumentError) do
      cancel(ModelInvocation.where(id: invocation.id), reason: "because_i_said_so")
    end

    assert_equal "unknown cancellation reason: because_i_said_so", error.message
    assert_predicate invocation.reload, :queued?
  end

  test "an empty cut returns zero" do
    assert_equal 0, cancel(ModelInvocation.where(id: -1))
  end

  test "the authority scopes have nonterminal partial indexes" do
    indexes = ApplicationRecord.lease_connection.indexes(:model_invocations).index_by(&:name)

    workspace = indexes.fetch("index_model_invocations_on_workspace_nonterminal")
    assert_equal %w[workspace_id id], workspace.columns
    assert_match(/status.*queued.*running/, workspace.where)

    creator = indexes.fetch("index_model_invocations_on_creator_nonterminal")
    assert_equal %w[creating_user_id id], creator.columns
    assert_match(/status.*queued.*running/, creator.where)
  end

  test "the aggregate derives its stopped status without a second write" do
    invocation = create_aggregate
    one_shot = invocation.one_shot
    updated_at = one_shot.updated_at

    cancel(ModelInvocation.where(id: invocation.id))

    assert_equal "canceled", one_shot.reload.status
    assert_equal updated_at, one_shot.updated_at
  end

  private

    def create_aggregate(workspace: @workspace, creating_user: @creator)
      one_shot = OneShot.create!(
        account: @account,
        workspace: workspace,
        creating_user: creating_user,
        workload: "text_generation"
      )
      DevModelLane.create_invocation!(one_shot: one_shot)
    end

    def cancel(scope, reason: "workspace_archived", **evidence)
      ModelInvocation::Cancellation.call(scope: scope, reason: reason, **evidence)
    end

    def capture_invocation_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        if !payload[:cached] && sql.match?(/(?:UPDATE|SELECT).*"model_invocations"/)
          statements << sql
        end
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) unless subscriber.nil?
    end
end
