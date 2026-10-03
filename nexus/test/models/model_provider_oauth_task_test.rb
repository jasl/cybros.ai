require "test_helper"

# C2-OAuth WP2: the private per-request authorization task.
class ModelProviderOAuthTaskTest < ActiveSupport::TestCase
  TASK = ModelProviderOAuthTask

  setup do
    @account = accounts(:cybros)
    @session = ModelProviderOAuthSession.create!(
      account: @account, issuing_user: users(:owner), provider_id: "codex_subscription",
      kind: "device_start", progress: "requesting_code",
      authorization_lineage_id: SecureRandom.uuid
    )
  end

  test "a task is born dispatching" do
    task = build_task

    assert_predicate task, :valid?
    task.save!

    assert_predicate task, :dispatching?
    refute_predicate task, :spent?
    assert_includes TASK.dispatching, task
  end

  # A retry is a NEW ROW, so nothing numbers resends and nothing refuses a
  # second row for the same step — the claim decides whether one may be
  # created at all, from the session's state.
  test "a session may carry many tasks for the same exchange kind" do
    build_task.save!

    assert_predicate build_task, :valid?
    build_task.save!

    assert_equal 2, @session.oauth_tasks.count
  end

  test "the result is recorded whole, and exactly when the state is terminal" do
    half_written = build_task
    half_written.normalized_status = "http_200"

    refute_predicate half_written, :valid?
    assert_includes half_written.errors.full_messages.join, "recorded whole"

    # And a terminal state with no result is the same violation from the other
    # side: the state and its explanation move together or not at all.
    unexplained = build_task
    unexplained.state = TASK::ANSWERED

    refute_predicate unexplained, :valid?
  end

  test "a task settles exactly once and the loser is told" do
    task = build_task.tap(&:save!)

    won = task.settle(
      state: TASK::ANSWERED, normalized_status: "http_200", result_kind: "user_code_issued"
    )
    lost = task.settle(
      state: TASK::SPENT, normalized_status: "timeout", result_kind: "no_response"
    )

    assert_equal TASK::ANSWERED, won.state
    assert_nil lost
    refute_predicate task.reload, :dispatching?
    assert_equal TASK::ANSWERED, task.state
  end

  test "the frozen claim facts raise on assignment after insert" do
    task = build_task.tap(&:save!)

    %i[exchange_kind claimed_at deadline_at].each do |field|
      assert_raises(ActiveRecord::ReadonlyAttributeError, field.to_s) do
        task.update!(field => task.public_send(field))
      end
    end
  end

  test "a parent cannot be deleted out from under its tasks" do
    build_task.save!

    # RESTRICT, not cascade: retention deletes the bounded children first, and
    # a cascade would let a parent delete destroy the only durable record that
    # a request was ever dispatched. Pinned at BOTH levels, because either
    # alone can be bypassed — the association guard by raw SQL, the constraint
    # by an application that never reaches the database.
    refute @session.destroy
    assert_includes @session.errors.full_messages.join, "oauth tasks"

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ModelProviderOAuthSession.lease_connection.execute(
        "DELETE FROM model_provider_oauth_sessions WHERE id = #{@session.id}"
      )
    end
    assert_includes error.message, "RESTRICT"
  end

  private

    def build_task(**overrides)
      now = Time.current
      TASK.new(
        account: @account, oauth_session: @session,
        exchange_kind: "user_code_request",
        claimed_at: now, deadline_at: now + 600,
        **overrides
      )
    end
end
