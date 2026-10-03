require "test_helper"

# The durable deadline sweep: the resolver three other designs already name.
#
# The two branches are the subject, because they are different work. An
# Attempt that never called a provider gives its hold back; one that spent its
# call gives nothing back and keeps settlement open until its own late-evidence
# window closes.
class ModelInvocations::DeadlineSweepTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @account.update!(cost_unit: "USD")
  end

  test "an unstarted attempt past its deadline is reaped with its parent" do
    attempt = admitted_attempt(model: DevModelLane::PRICED_TEXT_MODEL)
    expire(attempt)
    now = Time.current.change(usec: 0)
    clock_reads = 0

    result = DatabaseClock.stub(:now, -> { clock_reads += 1; now }) do
      ModelInvocations::DeadlineSweep.call
    end

    assert_equal 1, result[:timed_out]
    assert_equal 1, clock_reads, "the pass and both terminal rows share one database instant"
    attempt.reload
    assert_equal "timed_out", attempt.status
    assert_equal "not_applicable", attempt.settlement_state
    assert_equal now, attempt.terminal_at
    invocation = attempt.model_invocation.reload
    assert_equal "timed_out", invocation.status
    assert_equal now, invocation.terminal_at
  end

  # It spent its call, so settlement stays open: the provider may still have
  # answered, and pricing what it answered is the settlement path's job.
  test "a started attempt past its deadline closes with settlement open" do
    attempt = admitted_attempt(model: DevModelLane::PRICED_TEXT_MODEL)
    start(attempt)
    expire(attempt)

    assert_equal 1, ModelInvocations::DeadlineSweep.call[:timed_out]

    attempt.reload
    assert_equal "timed_out", attempt.status
    assert_equal "pending", attempt.settlement_state, "settlement is another owner's"
  end

  test "an attempt still inside its deadline is not touched" do
    attempt = admitted_attempt

    result = ModelInvocations::DeadlineSweep.call

    assert_equal 0, result[:timed_out]
    assert_equal "prepared", attempt.reload.status
  end

  # An expired Attempt under an ALREADY-terminal parent belongs to the post-cut converger, not here.
  # This sweep would answer `timed_out` over a cut that already said `canceled`, leaving parent and
  # child contradicting each other about one event; the converger copies the parent's word instead
  # of inventing one.
  test "an expired attempt under a cut parent is left to the post-cut converger" do
    attempt = admitted_attempt
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id), reason: "workspace_archived"
    )
    expire(attempt)

    assert_equal 0, ModelInvocations::DeadlineSweep.call[:timed_out]
    assert_equal "prepared", attempt.reload.status

    assert_equal 1, ModelInvocations::ConvergePostCut.call[:converged]
    assert_equal "canceled", attempt.reload.status, "one event, one word"
    assert_equal "canceled", attempt.model_invocation.reload.status
  end

  # The STARTED branch of the same hand-off. A started Attempt that spent its
  # call must keep settlement `pending` and take the parent's own word, which
  # is the converger's rule — this sweep would have written `timed_out` over a
  # cut that said `canceled`.
  test "an expired STARTED attempt under a cut parent is also left to the converger" do
    attempt = admitted_attempt
    start(attempt)
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id), reason: "workspace_archived"
    )
    expire(attempt)

    assert_equal 0, ModelInvocations::DeadlineSweep.call[:timed_out]
    assert_equal 1, ModelInvocations::ConvergePostCut.call[:converged]

    attempt.reload
    assert_equal "canceled", attempt.status, "one event, one word"
    assert_equal "pending", attempt.settlement_state
  end

  # The reason is frozen where an operator can read it a day later. The
  # Attempt's `timed_out` says which ordinal ran out; the Invocation's key says
  # the work did.
  test "the reaped parent records why it ended" do
    attempt = admitted_attempt
    expire(attempt)
    ModelInvocations::DeadlineSweep.call

    invocation = attempt.model_invocation.reload
    assert_equal "timed_out", invocation.status
    # ONE condition, ONE key. The execution host's start refusal reaches the
    # same row on the same test, and a caller must not see which owner won.
    assert_equal ModelInvocations::ProviderStart::DEADLINE_PASSED.to_s,
      invocation.failure_reason_key
  end

  # Level-triggered: running it twice is running it once.
  test "a second pass finds nothing and writes nothing" do
    attempt = admitted_attempt
    expire(attempt)
    assert_equal 1, ModelInvocations::DeadlineSweep.call[:timed_out]

    second = ModelInvocations::DeadlineSweep.call

    assert_equal 0, second[:timed_out]
    assert_equal 0, second[:scanned], "a terminal attempt has left the frontier"
  end

  test "a full batch reports a cursor and asks for a continuation" do
    3.times { |i| expire(admitted_attempt(ordinal: i + 1, fresh: true)) }

    result = ModelInvocations::DeadlineSweep.call(budget: 2)

    assert_equal 2, result[:scanned]
    assert_predicate result, :more?
    assert_equal 1, ModelInvocations::DeadlineSweep.call(budget: 2, after_id: result.cursor)[:timed_out]
  end

  private

    def expire(attempt)
      ModelInvocationAttempt.where(id: attempt.id).update_all(deadline_at: 1.minute.ago)
    end

    def start(attempt)
      invocation = attempt.model_invocation
      result = ModelInvocations::ProviderStart.call(
        attempt: attempt, host: "solid_queue",
        base_url: ModelCatalog.provider_base_url(invocation.provider_id),
        profile: DevModelLane.profile_for_invocation(invocation)
      )
      raise "start refused: #{result.outcome}" unless result.started?

      result
    end


    def admitted_attempt(model: nil, ordinal: 1, fresh: false)
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
          invocation: invocation, quote: quote, consumer: @human, payer: @human,
          ordinal: fresh ? 1 : ordinal
        )
      end
      raise "admission refused: #{admitted.outcome.inspect}" unless admitted.admitted?

      admitted.attempt
    end
end
