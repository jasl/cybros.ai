require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# C2-4 A15: the ordinal, and the invariant it protects.
#
# No partial unique index stands behind "at most one active attempt" — the
# Invocation lock does. So the concurrency test is not decoration here; it is
# the only thing that shows the claim is true.
class ModelInvocations::AttemptOrdinalTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @invocation = create_invocation
  end

  # This class runs WITHOUT the transactional wrapper, so every row it makes
  # is real and permanent for its worker — including the ones a single test
  # makes. `@extra_invocations` exists because forgetting them once left
  # attempts behind that a later test's `assert_equal 0,
  # ModelInvocationAttempt.count` reported as its own failure, in a different
  # file, only under some seeds.
  teardown do
    invocations = [@invocation, *@extra_invocations].compact
    ModelInvocationAttempt.where(model_invocation_id: invocations.map(&:id)).delete_all
    ModelInvocation.where(id: invocations.map(&:id)).delete_all
    OneShot.where(id: invocations.filter_map(&:one_shot_id)).delete_all
  end

  test "the first ordinal is one" do
    result = allocate

    assert_predicate result, :allocated?
    assert_equal 1, result.ordinal
  end

  test "an active attempt blocks a second allocation" do
    create_attempt(1)

    result = allocate

    assert_equal described::ACTIVE_EXISTS, result.refusal
  end

  # Ordinals count attempts and never reuse a number: a terminal attempt's
  # ordinal is part of its receipt identity, so the next allocation counts
  # past it rather than filling its place.
  test "a terminal attempt frees the slot but never its number" do
    create_attempt(1, status: "failed")

    result = allocate

    assert_equal 2, result.ordinal
  end

  test "the highest ordinal ever allocated is what the next one counts from" do
    create_attempt(1, status: "failed")
    create_attempt(2, status: "canceled")

    result = allocate

    assert_equal 3, result.ordinal
  end

  test "allocation reads the latest attempt once without aggregate queries" do
    create_attempt(1, status: "failed")
    create_attempt(2, status: "canceled")
    queries = []

    result = ApplicationRecord.transaction do
      @invocation.lock!
      subscriber = lambda do |*, payload|
        sql = payload.fetch(:sql)
        queries << sql if sql.include?('"model_invocation_attempts"')
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        described.next_for(@invocation)
      end
    end

    assert_equal 3, result.ordinal
    assert_equal 1, queries.length
    refute_match(/\b(?:COUNT|MAX|EXISTS)\b/i, queries.sole)
    assert_match(/ORDER BY .*ordinal.* DESC LIMIT/i, queries.sole)
  end

  # The claim under test: two allocators cannot both see "no active sibling".
  # Without the lock they would both allocate ordinal 1 and both insert, and
  # the unique index would turn one into an exception rather than an answer.
  test "two concurrent allocators serialize and exactly one gets a slot" do
    held = hold_row_lock(ModelInvocation, @invocation.id)
    calls = 2.times.map do
      start_database_call do
        ApplicationRecord.transaction do
          invocation = ModelInvocation.find(@invocation.id)
          invocation.lock!
          allocated = described.next_for(invocation)
          if allocated.allocated?
            ModelInvocationAttempt.create!(
              account_id: @account.id, model_invocation_id: @invocation.id,
              ordinal: allocated.ordinal, admission_shape: "admitted_free",
              deadline_at: 10.minutes.from_now
            )
          end
          allocated.refusal
        end
      end
    end
    wait_until_transitively_blocked_by(held.pid, *calls.map(&:pid))
    release_row_lock(held)
    held = nil
    refusals = calls.map { |call| finish_database_call(call) }
    calls = []

    assert_equal [nil, described::ACTIVE_EXISTS], refusals.sort_by(&:to_s),
      "one allocates, the other is told a live sibling exists"
    assert_equal 1, ModelInvocationAttempt.where(model_invocation_id: @invocation.id).count
  ensure
    begin
      release_row_lock(held) if held
    ensure
      Array(calls).each { |call| stop_database_call(call) }
    end
  end

  private

    def described = ModelInvocations::AttemptOrdinal

    def allocate(invocation = @invocation)
      ApplicationRecord.transaction do
        invocation.lock!
        described.next_for(invocation)
      end
    end

    def create_attempt(ordinal, status: "prepared")
      ModelInvocationAttempt.create!(
        account_id: @account.id, model_invocation_id: @invocation.id,
        ordinal: ordinal, admission_shape: "admitted_free", status: status,
        deadline_at: 10.minutes.from_now
      )
    end

    def create_invocation
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: selection.workload
      )
      DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
    end
end
