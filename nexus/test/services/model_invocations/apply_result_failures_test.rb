require "test_helper"
require "test_helpers/invocation_result_test_helper"

class ModelInvocations::ApplyResultFailuresTest < ActiveJob::TestCase
  include InvocationResultTestHelper

  # ---- failure: the transient/terminal split ------------------------------

  test "a 503 closes this ordinal and hands the invocation back with a cooldown" do
    attempt = admitted_attempt

    result = apply_via(attempt, json_response(503, { "error" => { "message" => "overloaded" } }))

    assert_predicate result, :requeued?
    attempt.reload
    assert_equal "failed", attempt.status
    invocation = attempt.model_invocation.reload
    assert_equal "queued", invocation.status
    assert_not_nil invocation.next_admission_at, "the cooldown is the deferral admission honours"
    assert_nil invocation.failure_reason_key
    receipt = receipt_for(attempt)
    assert_equal "failed", receipt.status, "a spent ordinal earns its receipt before the requeue"
    assert_equal "provider_overloaded", receipt.error_code, "the provider said it is overloaded, in its own word"
    assert_equal "settled", attempt.settlement_state
  end

  # OVERLOAD IS THE PROVIDER'S LOAD, never the account's quota or a transport loss: 503, 529 and the
  # streamed overload event name it per attempt; a 429 waits out the provider's floor and a 502 or
  # 504 is only transient.
  test "each attempt's receipt names overload only when the provider said so" do
    {
      503 => "provider_overloaded", 529 => "provider_overloaded",
      429 => "provider_http_error", 502 => "provider_http_error", 504 => "provider_http_error",
    }.each do |status, code|
      attempt = admitted_attempt
      apply_via(attempt, json_response(status, { "error" => { "message" => "busy" } }))
      assert_equal code, receipt_for(attempt).error_code, "HTTP #{status}"
    end
  end

  test "a retry-after header names the cooldown" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => "37" }))

    deferred_until = attempt.model_invocation.reload.next_admission_at
    assert_operator deferred_until, :>=, before + 36.seconds
    assert_operator deferred_until, :<=, before + 40.seconds
  end

  test "an HTTP-date retry-after is a Retry-After the provider named (re-audit)" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => 90.seconds.from_now.httpdate }))

    deferred_until = attempt.model_invocation.reload.next_admission_at
    assert_operator deferred_until, :>=, before + 85.seconds,
      "the predecessor honored both RFC forms; a date must not fall back to the 10s step"
    assert_operator deferred_until, :<=, before + 95.seconds
  end

  # The header is wire-controlled and the column is a datetime: an unbounded
  # digit string overflowed it server-side, aborting the terminal transaction
  # past every rescue (round 3).
  test "an absurd retry-after keeps the hour, not the strand" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    result = apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => "99999999999999999" }))

    assert_predicate result, :requeued?
    deferred_until = attempt.model_invocation.reload.next_admission_at
    assert_operator deferred_until, :<=, before + 3610.seconds
    assert_equal "settled", attempt.reload.settlement_state, "and the receipt landed"
  end

  # ---- THE PROVIDER ADMISSION FLOOR (owner 2026-09-15, item 11) ----------
  #
  # A Retry-After on an overloaded answer is the provider's word about the
  # LANE, so it lands on the (account, provider) row beside the attempt's
  # own cooldown — in the same transaction, from the transient set only,
  # never computed, never on a success, never past a lost CAS.

  def floor_row(invocation)
    ModelProviderRuntimeState.find_by(account_id: invocation.account_id, provider_id: invocation.provider_id)
  end

  # An attempt whose ordinal spends the budget on its failure (the shape
  # ExecuteAttemptTest drives): two settled predecessors, then the third.
  def last_budgeted_attempt
    first = admitted_attempt
    invocation = first.model_invocation
    first.update!(
      provider_started_at: Time.current, status: "failed", settlement_state: "settled",
      terminal_at: Time.current
    )
    ModelInvocationAttempt.create!(
      account: @account, model_invocation: invocation, ordinal: 2,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now,
      provider_started_at: Time.current, status: "failed", settlement_state: "settled",
      terminal_at: Time.current,
      consumer_public_id: first.consumer_public_id, payer_public_id: first.payer_public_id
    )
    ModelInvocationAttempt.create!(
      account: @account, model_invocation: invocation, ordinal: 3,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now,
      consumer_public_id: first.consumer_public_id, payer_public_id: first.payer_public_id
    )
  end

  test "a 429 with Retry-After on the requeue arm floors the lane at now plus the header" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    result = apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => "30" }))

    assert_predicate result, :requeued?
    row = floor_row(attempt.model_invocation)
    assert_not_nil row, "the provider's word lands on the lane, not the attempt alone"
    assert_operator row.next_admission_at, :>=, before + 29.seconds
    assert_operator row.next_admission_at, :<=, before + 33.seconds
    assert_in_delta row.next_admission_at.to_f, result.provider_floor_at.to_f, 0.001,
      "the Result carries the floor the terminal wake lands at"
    assert_in_delta row.next_admission_at.to_f, attempt.model_invocation.reload.next_admission_at.to_f, 0.001,
      "the per-attempt cooldown and the floor are the same instant on the requeue arm"
  end

  test "the floor commits with the disposition: a rolled-back apply leaves no row" do
    attempt = admitted_attempt

    ApplicationRecord.transaction do
      apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                                 headers: { "retry-after" => "30" }))
      raise ActiveRecord::Rollback
    end

    assert_nil floor_row(attempt.model_invocation), "same transaction as the requeue, or not at all"
  end

  test "a budget spent on a 429 terminalizes AND floors the lane" do
    attempt = last_budgeted_attempt
    before = DatabaseClock.now

    result = apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => "45" }))

    assert_predicate result, :applied?
    invocation = attempt.model_invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "attempt_budget_spent", invocation.failure_reason_key
    row = floor_row(invocation)
    assert_not_nil row, "the terminal arm carries the provider's word too"
    assert_operator row.next_admission_at, :>=, before + 44.seconds
    assert_in_delta row.next_admission_at.to_f, result.provider_floor_at.to_f, 0.001
  end

  test "a 503 with Retry-After floors the lane: the whole transient set, not 429 alone" do
    attempt = admitted_attempt

    apply_via(attempt, json_response(503, { "error" => { "message" => "overloaded" } },
                               headers: { "retry-after" => "12" }))

    assert_not_nil floor_row(attempt.model_invocation)
  end

  test "a 429 without Retry-After raises no floor and keeps the stepped cooldown" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    result = apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } }))

    assert_predicate result, :requeued?
    assert_nil floor_row(attempt.model_invocation), "no header, no floor: never a computed backoff"
    assert_nil result.provider_floor_at
    deferred_until = attempt.model_invocation.reload.next_admission_at
    assert_operator deferred_until, :>=, before + 9.seconds
    assert_operator deferred_until, :<=, before + 12.seconds
  end

  test "a Retry-After on a non-transient status raises no floor" do
    attempt = admitted_attempt

    result = apply_via(attempt, json_response(400, { "error" => { "message" => "bad request" } },
                               headers: { "retry-after" => "3600" }))

    assert_predicate result, :applied?
    assert_equal "failed", attempt.model_invocation.reload.status
    assert_nil floor_row(attempt.model_invocation),
      "a header on the caller's fault must not hold every sibling on the lane"
    assert_nil result.provider_floor_at
  end

  test "an HTTP-date Retry-After floors the lane at that date" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => 90.seconds.from_now.httpdate }))

    row = floor_row(attempt.model_invocation)
    assert_operator row.next_admission_at, :>=, before + 85.seconds
    assert_operator row.next_admission_at, :<=, before + 95.seconds
  end

  test "a past HTTP-date is a floor at now, which holds nothing" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => 90.seconds.ago.httpdate }))

    row = floor_row(attempt.model_invocation)
    assert_not_nil row, "the provider named a time; the row records it"
    assert_operator row.next_admission_at, :<=, before + 2.seconds
    assert_not row.floored?(DatabaseClock.now + 1), "and it never holds a candidate"
  end

  test "an absurd Retry-After floors the lane for the hour, not the strand" do
    attempt = admitted_attempt
    before = DatabaseClock.now

    apply_via(attempt, json_response(429, { "error" => { "message" => "slow down" } },
                               headers: { "retry-after" => "99999999999999999" }))

    row = floor_row(attempt.model_invocation)
    assert_operator row.next_admission_at, :<=, before + 3610.seconds
    assert_operator row.next_admission_at, :>=, before + 3590.seconds
  end

  test "a 429 that lost the CAS raises no floor" do
    attempt = admitted_attempt
    started = start(attempt)
    sent = nil
    fake_dispatch(json_response(429, { "error" => { "message" => "slow down" } },
                                headers: { "retry-after" => "30" })) do
      sent = ModelInvocations::Dispatch.call(
        attempt: attempt, context: started.context, request: build(attempt).request
      )
    end
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id), reason: "workspace_archived"
    )

    result = ModelInvocations::ApplyResult.call(attempt: attempt, outcome: sent)

    assert_equal ModelInvocations::ApplyResult::DISCARDED, result.outcome
    assert_nil floor_row(attempt.model_invocation), "the floor commits with the disposition or not at all"
    assert_nil result.provider_floor_at
  end

  test "a success never writes the floor row" do
    attempt = admitted_attempt

    result = apply_via(attempt, sse_success("the answer"))

    assert_nil floor_row(attempt.model_invocation)
    assert_nil result.provider_floor_at
  end

  test "a timeout is transient" do
    attempt = admitted_attempt

    result = apply_via(attempt, SimpleInference::TimeoutError.new("read timed out"))

    assert_predicate result, :requeued?
    assert_equal "queued", attempt.model_invocation.reload.status
  end

  test "an Anthropic stream overload is transient like HTTP 529" do
    attempt = admitted_attempt
    started = start(attempt)
    error = SimpleInference::Protocols::AnthropicMessages::StreamOverloadedError.new(
      "anthropic overloaded"
    )

    result = ModelInvocations::ApplyResult.call(
      attempt: started.attempt,
      outcome: outcome_for_error(error, profile: started.context.profile)
    )

    assert_predicate result, :requeued?
    assert_equal "queued", attempt.model_invocation.reload.status
    assert_equal "failed", receipt_for(attempt).status
  end

  # THE STREAMED OVERLOAD, parsed off the wire: an Anthropic stream that answers 200 and then says
  # `overloaded_error` mid-stream is the provider's 529 in another shape — each attempt's receipt
  # names it, and three of them make the work's key the fallback switches on.
  test "an Anthropic stream that ends in overloaded_error is overload on every attempt it spends" do
    attempt = admitted_attempt
    invocation = attempt.model_invocation
    receipts = 3.times.map do |index|
      if index.positive?
        ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
        attempt = ModelInvocations::AdmitQueuedWork.call.admitted.find { _1.invocation.id == invocation.id }.attempt
      end
      started = start(attempt)
      ModelInvocations::ApplyResult.call(attempt: started.attempt,
        outcome: outcome_for_error(streamed_overload, profile: started.context.profile))
      receipt_for(attempt.reload).error_code
    end

    assert_equal %w[provider_overloaded] * 3, receipts
    assert_equal %w[failed provider_overloaded], invocation.reload.values_at(:status, :failure_reason_key)
    assert_predicate invocation, :overloaded?
  end

  # The Anthropic protocol's own parse of a stream that began and then reported the overload.
  def streamed_overload
    frames = [
      %(event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant",) +
        %("content":[],"stop_reason":null,"usage":{"input_tokens":2,"output_tokens":0}}}\n\n),
      %(event: error\ndata: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}\n\n),
    ]
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new({ status: 200, headers: { "content-type" => "text/event-stream" },
                                                    sse: frames })
    )
    protocol.stream(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello").to_a
    flunk "the stream did not surface its overload"
  rescue SimpleInference::Protocols::AnthropicMessages::StreamOverloadedError => error
    error
  end

  # The hard stop: a spent budget is terminal, never a deferral — this is what keeps a provider that
  # fails forever from billing forever. When the provider said it was overloaded on EVERY attempt
  # the budget spent, the work's key says that: the one fact a declared fallback switches on.
  test "the third transient failure terminalizes instead of requeueing" do
    attempt = admitted_attempt
    invocation = attempt.model_invocation
    failure = -> { json_response(503, { "error" => { "message" => "still down" } }) }

    2.times do |index|
      before = DatabaseClock.now
      result = apply_via(attempt, failure.call)

      assert_predicate result, :requeued?
      expected_cooldown = ModelInvocations::ApplyResult::RETRY_COOLDOWN_STEP * attempt.ordinal
      deferred_until = invocation.reload.next_admission_at
      assert_operator deferred_until, :>=, before + expected_cooldown - 1.second
      assert_operator deferred_until, :<=, before + expected_cooldown + 5.seconds

      # Move only the scheduler's clock edge forward; admission and every
      # lifecycle transition below still run through the production commands.
      ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
      admission = ModelInvocations::AdmitQueuedWork.call.admitted
        .find { _1.invocation.id == invocation.id }
      assert_not_nil admission
      attempt = admission.attempt
      assert_equal index + 2, attempt.ordinal
    end

    result = apply_via(attempt, failure.call)

    assert_not result.requeued?
    invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "provider_overloaded", invocation.failure_reason_key, "overloaded on every attempt"
    assert_predicate invocation, :overloaded?
    assert_equal "HTTP 503: still down", invocation.failure_detail,
      "the spent budget keeps the last answer's sentence beside our own key"
    assert_equal "failed", receipt_for(attempt.reload).status
    assert_equal [1, 2, 3], invocation.attempts.order(:ordinal).pluck(:ordinal)

    # AND THE PROJECTION CARRIES BOTH FACTS. `attempt_budget_spent` is this
    # side's retry policy giving up; it says nothing about what went wrong
    # upstream, so a caller reading it alone learned only that we stopped —
    # and "retry later" and "fix your request" are the two answers a failed
    # turn has to distinguish. The provider's reason was never missing: it is
    # on the receipt this same transaction wrote, one row away.
    receipt = receipt_for(attempt.reload)
    projected = ModelInvocations::PublicError.render(invocation, receipt)
    assert_equal "provider_overloaded", projected.fetch("code")
    assert projected.fetch("attempt_budget_spent"),
      "and the budget is still reportable, as a caveat beside the code"
  end

  # Consecutive overloads, and nothing else, make the work's key: one transient answer of another
  # kind in the budget leaves it `attempt_budget_spent`, the code the caller acts on the provider's.
  test "a budget spent on mixed transient answers stays attempt_budget_spent" do
    attempt = admitted_attempt
    invocation = attempt.model_invocation
    [504, 504, 529].each_with_index do |status, index|
      if index.positive?
        ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
        attempt = ModelInvocations::AdmitQueuedWork.call.admitted.find { _1.invocation.id == invocation.id }.attempt
      end
      apply_via(attempt, json_response(status, { "error" => { "message" => "busy" } }))
    end

    assert_equal "attempt_budget_spent", invocation.reload.failure_reason_key
    assert_not_predicate invocation, :overloaded?
    projected = ModelInvocations::PublicError.render(invocation, receipt_for(attempt.reload))
    assert_equal ["provider_overloaded", true], projected.values_at("code", "attempt_budget_spent"),
      "the last receipt's word, with the budget as the caveat"
  end

  # THE CAVEAT IS ABSENT WHEN IT DOES NOT APPLY, on the `finish_quality`
  # precedent — a member to find, never a false to check. This is also the
  # guard on the shape a literal reading of the predecessor prescribes: a
  # global receipt-first would have answered here with an earlier ordinal's
  # row, because a swept deadline writes a reason and NO receipt of its own.
  test "an ordinary terminal failure projects its own code and no budget caveat" do
    attempt = admitted_attempt
    invocation = attempt.model_invocation

    apply_via(attempt, json_response(400, { "error" => { "message" => "bad request" } }))

    invocation.reload
    projected = ModelInvocations::PublicError.render(invocation, receipt_for(attempt.reload))
    assert_equal invocation.failure_reason_key, projected.fetch("code")
    refute projected.key?("attempt_budget_spent")
  end

  test "a 400 is the provider's answer and it is final" do
    attempt = admitted_attempt

    result = apply_via(attempt, json_response(400, { "error" => { "message" => "bad request" } }))

    assert_predicate result, :applied?
    invocation = attempt.model_invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "provider_http_error", invocation.failure_reason_key
    assert_equal "HTTP 400: bad request", invocation.failure_detail,
      "the status and the provider's sentence persist beside the key (12a F-5)"
    assert_equal "failed", attempt.reload.status
    receipt = receipt_for(attempt)
    assert_equal "failed", receipt.status
    assert_equal "provider_http_error", receipt.error_code
  end

  # ---- the CAS: a late answer never overwrites a cut ----------------------
  #
  # TWO windows, and the second is the one that shipped broken: after the
  # converger has closed the attempt, and BEFORE it has — when the kernel has
  # cut the invocation but the attempt still says `running`, which is the
  # cut\'s designed output for up to a minute. The first version rechecked
  # only the attempt and a routine 503 in that window resurrected a canceled
  # invocation into `queued`, where admission re-admitted it and paid for a
  # call nobody was owed.

  test "a result arriving after the converger closed the attempt is discarded" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")
    started = start(attempt)
    sent = nil
    fake_dispatch(json_response(200, {
      "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
    })) do
      sent = ModelInvocations::Dispatch.call(
        attempt: attempt, context: started.context, request: build(attempt).request
      )
    end
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id),
      reason: "workspace_archived"
    )
    assert_equal 1, ModelInvocations::ConvergePostCut.call[:converged]

    result = ModelInvocations::ApplyResult.call(attempt: attempt.reload, outcome: sent)

    assert_equal ModelInvocations::ApplyResult::DISCARDED, result.outcome
    invocation = attempt.model_invocation.reload
    assert_equal "canceled", invocation.status, "the first answer stands"
    assert_equal 0, invocation.output_files.count, "the late blobs were purged, not attached"
    assert_equal 0, ActiveStorage::Blob.where("filename LIKE ?", "#{invocation.public_id}%").count
    receipt = receipt_for(attempt)
    assert_equal "discarded", receipt.status, "a billed answer that lost the race was still billed"
    assert_nil receipt.error_code
    assert_equal "settled", attempt.reload.settlement_state,
      "the discarded receipt and settlement state land atomically"
  end

  test "a success in the kernel-to-converger window is discarded, not applied" do
    attempt = admitted_attempt
    started = start(attempt)
    sent = nil
    fake_dispatch(sse_success("too late")) do
      sent = ModelInvocations::Dispatch.call(
        attempt: attempt, context: started.context, request: build(attempt).request
      )
    end
    # The kernel cuts the INVOCATION and deliberately leaves the attempt to
    # the converger — which has NOT run: this is the designed window.
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id),
      reason: "workspace_archived"
    )
    assert_equal "running", attempt.reload.status, "the window is real, not staged"

    result = ModelInvocations::ApplyResult.call(attempt: attempt, outcome: sent)

    assert_equal ModelInvocations::ApplyResult::DISCARDED, result.outcome
    invocation = attempt.model_invocation.reload
    assert_equal "canceled", invocation.status
    assert_empty invocation.content_bodies.where(role: %w[response reasoning]),
      "no evidence lands on a canceled invocation"
    assert_equal "discarded", receipt_for(attempt).status
  end

  # THE MONEY CASE: the same window, a transient failure. The first version
  # flipped the canceled invocation back to `queued` here, and admission then
  # re-admitted revoked work and dispatched a new paid call for it.
  test "a transient failure in the kernel-to-converger window cannot resurrect the cut" do
    attempt = admitted_attempt
    started = start(attempt)
    sent = nil
    fake_dispatch(json_response(503, { "error" => { "message" => "overloaded" } })) do
      sent = ModelInvocations::Dispatch.call(
        attempt: attempt, context: started.context, request: build(attempt).request
      )
    end
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id),
      reason: "workspace_archived"
    )

    result = ModelInvocations::ApplyResult.call(attempt: attempt.reload, outcome: sent)

    assert_equal ModelInvocations::ApplyResult::DISCARDED, result.outcome
    invocation = attempt.model_invocation.reload
    assert_equal "canceled", invocation.status, "terminal is terminal; nothing un-cancels"
    assert_equal "workspace_archived", invocation.cancellation_reason
    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted,
      "and admission has nothing to re-admit"
    receipt = receipt_for(attempt)
    assert_equal "discarded", receipt.status
    assert_equal "provider_overloaded", receipt.error_code, "the wire's own answer rides beneath"
  end

  # The receipt writer uses a savepoint inside this terminal transaction. The
  # invalid deadline is not a receipt input, so insertion and summary update
  # happen before settlement validation fails; the caller rescues that known
  # failure, but only after the whole inner unit has rolled back.
  test "a late receipt validation failure rolls back its savepoint only" do
    attempt = admitted_attempt
    started = start(attempt)
    built = build(attempt)
    outcome = fake_dispatch(sse_success("still lands")) do
      ModelInvocations::Dispatch.call(
        attempt: started.attempt, context: started.context, request: built.request
      )
    end
    subject_id = attempt.model_invocation.one_shot_id
    invalidated_after_terminal = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if !invalidated_after_terminal &&
          sql.start_with?('UPDATE "model_invocation_attempts"') &&
          sql.include?('"status"')
        invalidated_after_terminal = true
        ModelInvocationAttempt.where(id: attempt.id).update_all(deadline_at: nil)
      end
    end

    begin
      result = ModelInvocations::ApplyResult.call(attempt: started.attempt, outcome: outcome)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert invalidated_after_terminal,
      "the invalid field must land after the pre-receipt Attempt update"
    assert_predicate result, :applied?
    attempt.reload
    assert_equal "completed", attempt.status
    assert_equal "pending", attempt.settlement_state, "the unwritten receipt stays owed and queryable"
    assert_equal "completed", attempt.model_invocation.reload.status
    assert_nil receipt_for(attempt)
    assert_not ModelUsageSummary.exists?(subject_kind: "one_shot", subject_id: subject_id)
  end
end
