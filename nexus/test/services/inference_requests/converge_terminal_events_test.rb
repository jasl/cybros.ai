require "test_helper"

# The events converger: one recorder for every terminal path, driven here
# through the REAL chain — admission, the start claim, dispatch against a
# fake adapter, terminal apply, and the real cancellation kernel.
class InferenceRequests::ConvergeTerminalEventsTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a completed answer earns run_status, preview, usage, and result" do
    attempt = admitted_attempt
    apply_via(attempt, sse_success("the answer"))
    invocation = attempt.model_invocation

    result = InferenceRequests::ConvergeTerminalEvents.call

    assert_equal 1, result[:recorded]
    assert_not_nil invocation.reload.terminal_event_recorded_at
    items = InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id).order(:sequence)
    assert_equal %w[run_status provider_output_item_completed usage result],
      items.map(&:item_type)
    assert_equal "completed", items.first.payload.fetch("status")
    assert_includes items.second.payload.fetch("content_preview"), "Mock: the answer"

    usage = items.third.payload.fetch("usage")
    assert_equal 2, usage.fetch("input_tokens")
    assert usage.fetch("cost_complete"), "the dev lane's known-free receipt is exact zero"

    envelope = items.map(&:inference_request_event).uniq.sole
    assert_equal invocation.public_id, envelope.idempotency_key
    payload = items.fourth.payload.fetch("result")
    assert_equal %w[inference_request_public_id status], payload.keys.sort
    assert_equal "completed", payload.fetch("status")
    assert_equal invocation.inference_request.public_id, payload.fetch("inference_request_public_id")
  end

  test "a second pass records nothing" do
    attempt = admitted_attempt
    apply_via(attempt, sse_success("hi"))
    assert_equal 1, InferenceRequests::ConvergeTerminalEvents.call[:recorded]

    result = InferenceRequests::ConvergeTerminalEvents.call

    assert_equal 0, result[:scanned], "the marker cleared the frontier"
    assert_equal 1, InferenceRequestEvent.where(inference_request_id: attempt.model_invocation.inference_request_id).count
  end

  test "a failed answer records the frozen reason on the result" do
    attempt = admitted_attempt
    apply_via(attempt, json_response(400, { "error" => { "message" => "bad request" } }))
    invocation = attempt.model_invocation

    InferenceRequests::ConvergeTerminalEvents.call

    items = InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id)
    result_payload = items.find_by(item_type: "result").payload.fetch("result")
    assert_equal "failed", result_payload.fetch("status")
    assert_equal "provider_http_error", result_payload.dig("error", "code")
    assert_nil items.find_by(item_type: "provider_output_item_completed"),
      "a failure has no output to preview"
  end

  test "a pending latest attempt never borrows an older usage receipt" do
    first = admitted_attempt
    apply_via(first, sse_success("first answer"))
    invocation = first.model_invocation
    old_receipt = UsageRecord.for_latest_attempt(invocation)
    assert old_receipt

    invocation.attempts.create!(
      account: @account,
      ordinal: first.ordinal + 1,
      admission_shape: first.admission_shape,
      status: "completed",
      settlement_state: "pending",
      terminal_at: Time.current,
      deadline_at: first.deadline_at,
      consumer_public_id: first.consumer_public_id,
      payer_public_id: first.payer_public_id
    )

    InferenceRequests::ConvergeTerminalEvents.call

    items = InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id)
    assert_nil items.find_by(item_type: "usage")
    result = items.find_by!(item_type: "result").payload.fetch("result")
    refute_includes result.to_json, old_receipt.public_id,
      "the terminal wake must not leak a superseded attempt receipt"
  end

  test "the kernel's cut converges into a canceled event with no usage" do
    inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: @human,
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(inference_request: inference_request)
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: invocation.id), reason: "workspace_archived"
    )
    assert_equal "canceled", invocation.reload.status

    result = InferenceRequests::ConvergeTerminalEvents.call

    assert_equal 1, result[:recorded]
    items = InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id)
    assert_equal "canceled", items.find_by(item_type: "run_status").payload.fetch("status")
    assert_nil items.find_by(item_type: "usage"), "never-started work has no receipt to project"
  end

  test "an unwritable event costs the event, never the marker or the pass" do
    first = admitted_attempt
    apply_via(first, sse_success("one"))
    second = admitted_attempt(creator: users(:owner))
    apply_via(second, sse_success("two"))

    invalid = ActiveRecord::RecordInvalid.new(InferenceRequestEvent.new)
    calls = 0
    result = InferenceRequestEvents::Append.stub(:call, lambda { |**args|
      calls += 1
      raise invalid if calls == 1

      InferenceRequestEvents::Append.new(**args).call
    }) do
      InferenceRequests::ConvergeTerminalEvents.call
    end

    assert_equal 1, result[:recorded], "the surviving row's event; the refused one is marker-only"
    assert_equal 2, ModelInvocation.where.not(terminal_event_recorded_at: nil).count,
      "both rows left the frontier"
    assert_equal 1, InferenceRequestEvent.count, "one event landed, one was honestly lost to the log"
  end

  # The stated property is the SAVEPOINT, and the stub above cannot test it
  # (it raises before any SQL). Every real refusal is mid-append — envelope
  # and run_status land before a refusable payload — so this drives the real
  # Append into a later item's refusal and asserts the rollback is WHOLE: a
  # partial terminal event committed beside the marker is corrupted replay.
  test "a mid-append refusal rolls the whole event back, never half of it" do
    attempt = admitted_attempt
    apply_via(attempt, sse_success("fine"))
    poisoned = [
      { type: "run_status", payload: { "status" => "completed" } },
      { type: "result", payload: { "result" => "x" * 70_000 } },
    ]

    result = ModelInvocations::TerminalEventItems.stub(:call, poisoned) do
      InferenceRequests::ConvergeTerminalEvents.call
    end

    assert_equal 0, result[:recorded], "nothing appended is nothing recorded"
    assert_equal 1, result[:scanned]
    invocation = attempt.model_invocation.reload
    assert_not_nil invocation.terminal_event_recorded_at, "but the marker still dealt with the row"
    assert_empty InferenceRequestEvent.where(inference_request_id: invocation.inference_request_id),
      "the envelope and the run_status item must not outlive their refused sibling"
    assert_empty InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id)
  end

  # The frontier's status leg, pinned after review: without it the converger
  # locks live rows, records nothing, and never drains its own frontier.
  test "a live invocation is not the frontier's business" do
    attempt = admitted_attempt
    assert_equal "running", attempt.model_invocation.status

    result = InferenceRequests::ConvergeTerminalEvents.call

    assert_equal 0, result[:scanned]
  end

  test "a full budget reports more and the next pass finishes the frontier" do
    first = admitted_attempt
    apply_via(first, sse_success("one"))
    second = admitted_attempt(creator: users(:owner))
    apply_via(second, sse_success("two"))

    result = InferenceRequests::ConvergeTerminalEvents.call(budget: 1)
    assert_equal 1, result[:recorded]
    assert_predicate result, :more?

    rest = InferenceRequests::ConvergeTerminalEvents.call(budget: 1)
    assert_equal 1, rest[:recorded]
    assert_not_predicate InferenceRequests::ConvergeTerminalEvents.call(budget: 1), :more?
  end

  test "a long answer keeps its event and loses only the preview's tail" do
    attempt = admitted_attempt
    apply_via(attempt, sse_success("y" * 70_000))

    assert_equal 1, InferenceRequests::ConvergeTerminalEvents.call[:recorded]

    preview = InferenceRequestEventItem
      .find_by(inference_request_id: attempt.model_invocation.inference_request_id,
        item_type: "provider_output_item_completed")
      .payload.fetch("content_preview")
    assert_equal 1_000, preview.length
  end

  test "the run job wakes the converger on a terminal apply" do
    attempt = admitted_attempt
    clear_enqueued_jobs

    fake_dispatch(sse_success("hi")) do
      ModelInvocations::RunJob.perform_now(attempt.public_id)
    end

    assert_enqueued_with(job: InferenceRequests::ConvergeTerminalEventsJob)
  end
end
