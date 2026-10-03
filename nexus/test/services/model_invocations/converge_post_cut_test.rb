require "test_helper"

# Post-cut convergence: the half the cancellation kernel deliberately does not
# do. Until this existed, a canceled Invocation left its Attempt `prepared`
# forever.
class ModelInvocations::ConvergePostCutTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @account.update!(cost_unit: "USD")
  end

  test "an unstarted attempt under a cut parent ends with the cut's own class" do
    attempt = admitted_attempt(model: DevModelLane::PRICED_TEXT_MODEL)
    cut(attempt.model_invocation)

    result = ModelInvocations::ConvergePostCut.call

    assert_equal 1, result[:converged]
    attempt.reload
    assert_equal "canceled", attempt.status, "the attempt copies the cut's own class"
    assert_equal "not_applicable", attempt.settlement_state
  end

  # A started attempt spent its call, so settlement stays open — a local
  # authority cut does not make late provider evidence untrue.
  test "a started attempt copies the class but keeps its settlement open" do
    attempt = admitted_attempt(model: DevModelLane::PRICED_TEXT_MODEL)
    start(attempt)
    cut(attempt.model_invocation)

    assert_equal 1, ModelInvocations::ConvergePostCut.call[:converged]

    attempt.reload
    assert_equal "canceled", attempt.status
    assert_equal "pending", attempt.settlement_state
  end

  # The parent is the first winner and stays it.
  test "convergence never rewrites the cut it is converging to" do
    attempt = admitted_attempt
    invocation = attempt.model_invocation
    cut(invocation)
    reason = invocation.reload.cancellation_reason
    cut_at = invocation.canceled_at

    ModelInvocations::ConvergePostCut.call

    invocation.reload
    assert_equal "canceled", invocation.status
    assert_equal reason, invocation.cancellation_reason
    assert_equal cut_at, invocation.canceled_at
  end

  test "an attempt under a live parent is left alone" do
    attempt = admitted_attempt

    result = ModelInvocations::ConvergePostCut.call

    assert_equal 0, result[:converged]
    assert_equal "prepared", attempt.reload.status
  end

  test "healthy attempts are filtered by one bounded parent lookup" do
    3.times { admitted_attempt }
    queries = []
    subscriber = lambda do |*, payload|
      sql = payload.fetch(:sql)
      queries << sql if sql.include?('"model_invocation_attempts"') ||
        sql.include?('"model_invocations"')
    end

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      ModelInvocations::ConvergePostCut.call
    end

    assert_equal 0, result[:converged]
    assert_equal 1, queries.count { _1.include?('"model_invocation_attempts"') }
    assert_equal 1, queries.count { _1.include?('"model_invocations"') }
  end

  # Level-triggered: running it twice is running it once.
  test "a second pass finds nothing" do
    attempt = admitted_attempt
    cut(attempt.model_invocation)
    assert_equal 1, ModelInvocations::ConvergePostCut.call[:converged]

    assert_equal 0, ModelInvocations::ConvergePostCut.call[:converged]
  end

  # A completed parent with an active attempt is a contradiction, and writing
  # a plausible row over it would destroy the evidence that something upstream
  # is wrong. It is skipped, not repaired — and NOT raised, which is a
  # different rule: the frontier is a keyset walk in id order, so a raise here
  # stopped every higher id from ever converging, leaving unrelated execution
  # and settlement state stale once a minute forever. The deadline
  # sweep now leaves terminal-parent rows to this pass, so this is the only
  # owner such a row has.
  test "a completed parent with an active attempt is skipped, not repaired" do
    attempt = admitted_attempt
    attempt.model_invocation.update!(status: "completed", terminal_at: Time.current)
    healthy = admitted_attempt
    healthy.model_invocation.update!(status: "canceled", terminal_at: Time.current)

    assert_equal 1, ModelInvocations::ConvergePostCut.call[:converged]

    assert_equal "prepared", attempt.reload.status, "nothing was repaired over it"
    assert_equal "canceled", healthy.reload.status,
      "and the rows behind it still converge"
  end

  # The same isolation for anything else that goes wrong on one row.
  test "a row that raises does not take the rest of the batch with it" do
    poisoned = admitted_attempt
    poisoned.model_invocation.update!(status: "canceled", terminal_at: Time.current)
    healthy = admitted_attempt
    healthy.model_invocation.update!(status: "canceled", terminal_at: Time.current)
    boom = ->(**) { raise "synthetic failure" }

    converged = ModelInvocations::CancelUnstarted.stub(:call, boom) do
      ModelInvocations::ConvergePostCut.call[:converged]
    end

    assert_equal 0, converged
    assert_equal 2, ModelInvocations::ConvergePostCut.call[:converged],
      "the pass survived, and both rows are still there to converge"
  end

  # THE CUT WINS OVER A STARTED ATTEMPT, and that is the ported answer rather
  # than a regression. There was a first-winner fence here: a NOT EXISTS
  # proving the current attempt had not already ACCEPTED a provider terminal,
  # which would leave the parent `running`. It read a column no writer ever
  # set, so it excluded nothing, and Stage 3 removed both.
  #
  # The predecessor arbitrated this race on the attempt's own status: its
  # terminal writer refused a row that was not `running`, so a cut that landed
  # first won and the late provider result was recorded as discarded usage.
  # The ported terminal apply does the same, which puts the contention in one
  # place instead of two.
  test "a cut stops a started attempt, and the converger copies its class" do
    attempt = admitted_attempt
    start(attempt)
    invocation = attempt.model_invocation

    cut(invocation)

    assert_equal "canceled", invocation.reload.status
    assert_equal 1, ModelInvocations::ConvergePostCut.call[:converged]
    assert_equal "canceled", attempt.reload.status
    assert_equal "pending", attempt.settlement_state,
      "the call was made; only the provider can close its settlement"
  end

  private

    def cut(invocation)
      ModelInvocation::Cancellation.call(
        scope: ModelInvocation.where(id: invocation.id), reason: "workspace_archived"
      )
    end

    def start(attempt)
      invocation = attempt.model_invocation
      result = ModelInvocations::ProviderStart.call(
        attempt: attempt, host: "solid_queue",
        base_url: ModelCatalog.provider_base_url(invocation.provider_id),
        profile: DevModelLane.profile_for_invocation(invocation)
      )
      raise "start refused: #{result.outcome}" unless result.started?
    end


    def admitted_attempt(model: nil)
      selection = DevModelLane.selection(
        workload: "text_generation", account: @account, **(model ? { model: model } : {})
      )
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @human,
        workload: selection.workload
      )
      invocation = DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
      quote = ModelInvocations::AdmissionCandidate.call(invocation: invocation)
      admitted = ApplicationRecord.transaction do
        PrincipalLocks.descend(@human)
        invocation.lock!
        invocation.update!(status: "running")
        ModelInvocations::AdmitUsage.call(
          invocation: invocation, quote: quote, consumer: @human, payer: @human, ordinal: 1
        )
      end
      raise "admission refused: #{admitted.outcome.inspect}" unless admitted.admitted?

      admitted.attempt
    end
end
