require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# The parent Invocation lock arbitrates concurrent hosts and authority cuts.
class ModelInvocations::ProviderStartRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @invocation = create_invocation
    @invocation.update!(status: "running")
    @attempt = ModelInvocationAttempt.create!(
      account: @account, model_invocation: @invocation,
      ordinal: 1, admission_shape: "admitted_free", deadline_at: 10.minutes.from_now
    )
  end

  teardown do
    ModelInvocationAttempt.where(model_invocation_id: @invocation.id).delete_all
    ModelInvocation.where(id: @invocation.id).delete_all
    InferenceRequest.where(id: @inference_request_id).delete_all
  end

  test "two hosts starting the same attempt at once produce exactly one start" do
    # Both callers block on the Invocation lock, so they are guaranteed to be
    # inside `claim` together rather than accidentally serialized by timing.
    held = hold_row_lock(ModelInvocation, @invocation.id)
    calls = %w[model_runner solid_queue].map do |host|
      start_database_call { start(host: host) }
    end
    wait_until_transitively_blocked_by(held.pid, *calls.map(&:pid))
    release_row_lock(held)
    held = nil

    results = calls.map { |call| finish_database_call(call) }
    calls = []
    results.each { |result| raise result if result.is_a?(Exception) }

    outcomes = results.map(&:outcome)
    assert_equal 1, outcomes.count(ModelInvocations::ProviderStart::STARTED),
      "exactly one host may start an attempt"
    assert_equal [ModelInvocations::ProviderStart::ALREADY_STARTED],
      outcomes - [ModelInvocations::ProviderStart::STARTED]

    # The winner owns the only send context; the loser cannot start the row.
    winner = results.find(&:started?)
    attempt = @attempt.reload
    assert_includes %w[model_runner solid_queue], winner.context.host
    assert_not_nil attempt.provider_started_at
    assert_equal "running", @invocation.reload.status
  end

  test "a committed authority cut prevents a waiting provider start" do
    held = hold_row_lock(
      ModelInvocation,
      @invocation.id,
      before_commit: ->(*) {
        ModelInvocation::Cancellation.call(
          scope: ModelInvocation.where(id: @invocation.id),
          reason: "workspace_archived"
        )
      }
    )
    starting = start_database_call { start(host: "solid_queue") }
    wait_until_transitively_blocked_by(held.pid, starting.pid)

    release_row_lock(held)
    held = nil
    result = finish_database_call(starting)
    starting = nil

    assert_equal ModelInvocations::ProviderStart::AUTHORITY_LOST, result.outcome
    assert_predicate @invocation.reload, :canceled?
    @attempt.reload
    assert_predicate @attempt, :prepared?
    assert_nil @attempt.provider_started_at
  ensure
    release_row_lock(held) unless held.nil?
    stop_database_call(starting) unless starting.nil?
  end

  private

    def start(host:)
      attempt = ModelInvocationAttempt.find(@attempt.id)
      invocation = attempt.model_invocation
      ModelInvocations::ProviderStart.call(
        attempt: attempt, host: host,
        base_url: ModelCatalog.provider_base_url(invocation.provider_id),
        profile: DevModelLane.profile_for_invocation(invocation)
      )
    end

    def create_invocation
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: selection.workload
      )
      @inference_request_id = inference_request.id
      DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
    end
end
