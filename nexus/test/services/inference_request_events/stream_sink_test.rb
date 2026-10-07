require "test_helper"
require "test_helpers/log_capture"
# Kernel#Sync comes with the async gem, which loads lazily with the runner
# host — this suite's reactor-timer pins need it regardless of test order.
require "async"

# The durable narration: byte-for-byte losslessness through the coalescing
# window and the chunker, the running-only delta gate, and the rollback
# marker's narrower contract.
class InferenceRequestEvents::StreamSinkTest < ActiveJob::TestCase
  include InvocationHarness
  include LogCapture

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "streamed text survives the window byte for byte, whitespace included" do
    attempt = started_attempt
    sink = sink_for(attempt, flush_interval_ms: 0)

    ["Hel", "lo ", "\n\n", "world"].each do |fragment|
      sink.on_event(attempt.model_invocation, text_delta(fragment))
    end
    sink.on_stream_settled(attempt.model_invocation)

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal "Hello \n\nworld", texts.join
  end

  test "a burst coalesces while the first fragment lands immediately" do
    attempt = started_attempt
    clock = [0.0]
    sink = sink_for(attempt, flush_interval_ms: 100, clock: -> { clock[0] })

    sink.on_event(attempt.model_invocation, text_delta("Hel"))
    clock[0] = 0.01
    sink.on_event(attempt.model_invocation, text_delta("lo "))
    sink.on_event(attempt.model_invocation, text_delta("world"))
    clock[0] = 0.2
    sink.on_stream_settled(attempt.model_invocation)

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal ["Hel", "lo world"], texts, "leading edge immediate, tail coalesced"
  end

  test "a key switch flushes the pending tail first, preserving order" do
    attempt = started_attempt
    clock = [0.0]
    sink = sink_for(attempt, flush_interval_ms: 100, clock: -> { clock[0] })

    sink.on_event(attempt.model_invocation, text_delta("answer"))
    clock[0] = 0.01
    sink.on_event(attempt.model_invocation, text_delta(" tail"))
    sink.on_event(attempt.model_invocation, reasoning_delta("because"))
    sink.on_stream_settled(attempt.model_invocation)

    items = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id)
      .order(:sequence).map { |item| [item.item_type, item.payload["text"]] }
    assert_equal [["text_delta", "answer"], ["text_delta", " tail"],
                  ["reasoning_delta", "because"]], items
  end

  test "reasoning deltas carry their kind" do
    attempt = started_attempt
    sink = sink_for(attempt, flush_interval_ms: 0)

    sink.on_event(attempt.model_invocation, reasoning_delta("thinking", kind: "summary_text"))
    sink.on_stream_settled(attempt.model_invocation)

    item = InferenceRequestEventItem.find_by(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "reasoning_delta")
    assert_equal "summary_text", item.payload.fetch("kind")
  end

  test "a large delta chunks under the payload bound and stays lossless" do
    attempt = started_attempt
    sink = sink_for(attempt, flush_interval_ms: 0)
    text = "x" * 40_000

    sink.on_event(attempt.model_invocation, text_delta(text))
    sink.on_stream_settled(attempt.model_invocation)

    items = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").order(:sequence)
    assert_operator items.count, :>, 1
    assert_equal text, items.map { |item| item.payload.fetch("text") }.join
  end

  test "another invocation's events are not this sink's business" do
    attempt = started_attempt
    other = started_attempt(creator: users(:owner))
    sink = sink_for(attempt, flush_interval_ms: 0)

    sink.on_event(other.model_invocation, text_delta("foreign"))
    sink.on_stream_settled(attempt.model_invocation)

    assert_empty InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id)
  end

  test "a terminal invocation takes no further narration, and the refusal is not silent" do
    attempt = started_attempt
    sink = sink_for(attempt, flush_interval_ms: 0)
    sink.on_event(attempt.model_invocation, text_delta("before"))
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id),
      reason: "workspace_archived"
    )

    lines = capture_log do
      sink.on_event(attempt.model_invocation, text_delta("after the cut"))
      sink.on_stream_settled(attempt.model_invocation)
    end

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").map { |item| item.payload.fetch("text") }
    assert_equal ["before"], texts, "the first answer stands"
    line = lines.grep(/event=inference_request_narration_dropped/).sole
    assert_includes line, "invocation=#{attempt.model_invocation.public_id}"
    assert_includes line, "status=canceled"
    assert_includes line, "bytes=#{"after the cut".bytesize}"
  end

  # The terminal-flush race: the timer takes the window and `response.completed` lands inside its
  # round trips. The settle must own that flush — wait for it — or ApplyResult commits the terminal
  # status first and the timer's gated append is refused: the reply short by its last window.
  test "the settle waits for a timer flush in flight" do
    attempt = started_attempt
    invocation = attempt.model_invocation
    sink = sink_for(attempt, flush_interval_ms: 20, clock: -> { 0.0 })
    taken = Async::Condition.new
    release = Async::Condition.new

    Sync do |task|
      sink.on_event(invocation, text_delta("lead"))
      # The timer's append, parked between taking the buffer and its commit.
      sink.define_singleton_method(:append_coalesced_delta) do |key, text|
        taken.signal
        release.wait
        super(key, text)
      end
      sink.on_event(invocation, text_delta(" tail"))
      taken.wait

      settled = task.async { sink.on_stream_settled(invocation) }
      assert_not_predicate settled, :finished?,
        "the settle returned while the timer's append was still in flight"
      release.signal
      settled.wait
    end

    texts = InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id,
      item_type: "text_delta").order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal ["lead", " tail"], texts
  end

  test "a retry rolls back only when something public streamed" do
    quiet = started_attempt
    quiet_sink = sink_for(quiet, flush_interval_ms: 0)
    quiet_sink.on_retry(quiet.model_invocation)
    assert_empty InferenceRequestEventItem.where(inference_request_id: quiet.model_invocation.inference_request_id),
      "no deltas, no rollback"

    loud = started_attempt(creator: users(:owner))
    loud_sink = sink_for(loud, flush_interval_ms: 0)
    loud_sink.on_event(loud.model_invocation, text_delta("partial"))
    loud_sink.on_retry(loud.model_invocation)

    items = InferenceRequestEventItem.where(inference_request_id: loud.model_invocation.inference_request_id)
      .order(:sequence).pluck(:item_type)
    assert_equal %w[text_delta rollback], items
  end

  # A declined answer is discarded from storage, so its streamed partial is
  # withdrawn the way a retry's is — one marker, its reason `refused` — and
  # only when something public went out.
  test "a refusal rolls back only when something public streamed, naming why" do
    quiet = started_attempt
    quiet_sink = sink_for(quiet, flush_interval_ms: 0)
    quiet_sink.on_refused(quiet.model_invocation)
    assert_empty InferenceRequestEventItem.where(inference_request_id: quiet.model_invocation.inference_request_id)

    loud = started_attempt(creator: users(:owner))
    clock = [0.0]
    loud_sink = sink_for(loud, flush_interval_ms: 100, clock: -> { clock[0] })
    loud_sink.on_event(loud.model_invocation, text_delta("partial"))
    clock[0] = 0.01
    loud_sink.on_event(loud.model_invocation, text_delta(" pending tail"))
    loud_sink.on_refused(loud.model_invocation)

    items = InferenceRequestEventItem.where(inference_request_id: loud.model_invocation.inference_request_id).order(:sequence)
    assert_equal %w[text_delta rollback], items.map(&:item_type), "the pending tail is dropped, never flushed"
    assert_equal({ "inference_request_public_id" => loud.model_invocation.inference_request.public_id, "reason" => "refused" },
      items.last.payload)
  end

  test "the rollback lands after the requeue but never after a newer ordinal starts" do
    attempt = started_attempt
    sink = sink_for(attempt, flush_interval_ms: 0)
    sink.on_event(attempt.model_invocation, text_delta("partial"))
    # The transient path: attempt failed, invocation queued — the state
    # on_retry actually fires in.
    apply_transient_failure(attempt)

    sink.on_retry(attempt.model_invocation)
    assert_equal 1, InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "rollback").count, "queued is not terminal; the marker lands"

    # A newer ordinal starts: a LATE duplicate rollback must not land.
    ModelInvocationAttempt.create!(
      account: @account, model_invocation: attempt.model_invocation,
      ordinal: attempt.ordinal + 1, admission_shape: "admitted_free",
      deadline_at: 10.minutes.from_now, provider_started_at: Time.current,
      status: "running", settlement_state: "pending",
      consumer_public_id: @human.public_id, payer_public_id: @human.public_id
    )
    late = sink_for(attempt, flush_interval_ms: 0)
    late.on_event(attempt.model_invocation, text_delta("ghost"))
    late.instance_variable_set(:@emitted_public_delta, true)
    late.on_retry(attempt.model_invocation)

    assert_equal 1, InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "rollback").count, "the stream belongs to the newer ordinal now"
  end

  # The predecessor's coalescing matrix legs the port left unpinned until
  # the item-5 review counted them: byte cap, age flush, the reactor timer,
  # and the timer-failure degradation.
  test "the byte cap flushes a fat buffer before the window elapses" do
    attempt = started_attempt
    clock = [0.0]
    sink = sink_for(attempt, flush_interval_ms: 100, flush_bytes: 8, clock: -> { clock[0] })

    sink.on_event(attempt.model_invocation, text_delta("a"))
    clock[0] = 0.01
    sink.on_event(attempt.model_invocation, text_delta("bbbb"))
    sink.on_event(attempt.model_invocation, text_delta("cccc"))

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal ["a", "bbbbcccc"], texts, "8 bytes crossed; the buffer flushed without settling"
  end

  test "an aged buffer flushes on the next fragment" do
    attempt = started_attempt
    clock = [0.0]
    sink = sink_for(attempt, flush_interval_ms: 100, clock: -> { clock[0] })

    sink.on_event(attempt.model_invocation, text_delta("first"))
    clock[0] = 0.01
    sink.on_event(attempt.model_invocation, text_delta(" old"))
    clock[0] = 0.5
    sink.on_event(attempt.model_invocation, text_delta(" fragment"))

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal ["first", " old fragment"], texts
  end

  test "the reactor timer flushes an expired tail with no further fragment" do
    attempt = started_attempt
    sink = sink_for(attempt, flush_interval_ms: 30)

    Sync do
      sink.on_event(attempt.model_invocation, text_delta("lead"))
      sink.on_event(attempt.model_invocation, text_delta(" tail"))
      sleep(0.2)
    end

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal ["lead", " tail"], texts, "the transient task is the only thing that could flush it"
  end

  test "a failed timer flush surfaces on the next callback as the stashed error" do
    attempt = started_attempt
    # A FROZEN coalescing clock: under a loaded suite the gap between the
    # two on_event calls can exceed the interval, making the tail its own
    # leading edge whose synchronous flush raises straight through the stub
    # instead of stashing (the flake this pins away). With elapsed pinned to
    # zero the tail always coalesces onto the reactor timer, which runs on
    # real time and fires inside the sleep.
    sink = sink_for(attempt, flush_interval_ms: 30, clock: -> { 0.0 })
    Sync do
      sink.on_event(attempt.model_invocation, text_delta("lead"))
      # The stub is installed BEFORE the tail schedules its timer: the timer
      # could otherwise fire in the gap and flush cleanly, and the test
      # would assert an error nothing stashed.
      sink.stub(:append_coalesced_delta, ->(*) { raise "storage refused" }) do
        sink.on_event(attempt.model_invocation, text_delta(" tail"))
        sleep(0.2)
      end
    end

    assert_raises(ModelInvocations::DeltaCoalescing::FlushError) do
      sink.on_stream_settled(attempt.model_invocation)
    end
  end

  test "cancel discards the pending tail without appending" do
    attempt = started_attempt
    clock = [0.0]
    sink = sink_for(attempt, flush_interval_ms: 100, clock: -> { clock[0] })
    sink.on_event(attempt.model_invocation, text_delta("kept"))
    clock[0] = 0.01
    sink.on_event(attempt.model_invocation, text_delta(" pending"))

    sink.on_stream_canceled(attempt.model_invocation)
    clock[0] = 0.5
    sink.on_stream_settled(attempt.model_invocation)

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").map { |item| item.payload.fetch("text") }
    assert_equal ["kept"], texts
  end

  private

    def started_attempt(creator: nil)
      attempt = admitted_attempt(creator: creator)
      result = start(attempt)
      @contexts ||= {}
      @contexts[result.attempt.id] = result.context
      result.attempt
    end

    def sink_for(attempt, **coalescing)
      InferenceRequestEvents::StreamSink.new(attempt: attempt, **coalescing)
    end

    def text_delta(text)
      SimpleInference::Responses::Events::TextDelta.new(delta: text)
    end

    def reasoning_delta(text, kind: "reasoning_text")
      SimpleInference::Responses::Events::ReasoningDelta.new(delta: text, kind: kind)
    end

    def apply_transient_failure(attempt)
      fake_dispatch(json_response(503, { "error" => { "message" => "overloaded" } })) do
        sent = ModelInvocations::Dispatch.call(
          attempt: attempt, context: @contexts.fetch(attempt.id), request: build(attempt).request
        )
        ModelInvocations::ApplyResult.call(attempt: attempt, outcome: sent)
      end
    end
end
