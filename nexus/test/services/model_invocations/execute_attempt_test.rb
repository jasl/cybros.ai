require "test_helper"

# The host-agnostic execution sequence's ONE judgment change from the RunJob
# it was extracted from: a pair refusal is write-free, not terminal.
class ModelInvocations::ExecuteAttemptTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a model hidden after admission is refused before any provider IO" do
    attempt = admitted_attempt
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.set_model_visibility("dev/mock-text", visible: false)
    policy.save!

    fake_dispatch(sse_success("unused")) do |adapter|
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "model_runner")
      assert_empty adapter.requests
    end

    assert_equal "failed", attempt.reload.status
    assert_equal "model_hidden", attempt.model_invocation.reload.failure_reason_key
    refute_predicate attempt, :started?
  end

  test "a model marked unavailable after admission is refused before provider IO" do
    attempt = admitted_attempt
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.set_model_availability("dev/mock-text", available: false)
    policy.save!

    fake_dispatch(sse_success("unused")) do |adapter|
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "model_runner")
      assert_empty adapter.requests
    end

    assert_equal "failed", attempt.reload.status
    assert_equal "model_hidden", attempt.model_invocation.reload.failure_reason_key
    refute_predicate attempt, :started?
  end

  test "hiding a started model preserves its result and settlement" do
    attempt = admitted_attempt
    dispatch = ModelInvocations::Dispatch.method(:call)
    hide_then_dispatch = ->(**arguments, &block) do
      policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
      policy.set_model_visibility("dev/mock-text", visible: false)
      policy.save!
      dispatch.call(**arguments, &block)
    end

    fake_dispatch(sse_success("finished")) do |adapter|
      ModelInvocations::Dispatch.stub(:call, hide_then_dispatch) do
        ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "model_runner")
      end
      assert_equal 1, adapter.requests.length
    end

    assert_equal "completed", attempt.reload.status
    assert_equal "settled", attempt.settlement_state
    assert UsageRecord.exists?(model_invocation_public_id: attempt.model_invocation.public_id)
  end

  test "a lane routed elsewhere is left for its host, never terminalized" do
    attempt = admitted_attempt(workload: "embedding", model: "dev/mock-embedding",
      input: "embed me")

    ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "model_runner")

    attempt.reload
    assert_equal "prepared", attempt.status,
      "the runner does not own this lane; the queue host's job still will"
    assert_equal "running", attempt.model_invocation.reload.status
  end

  test "current catalog wire facts drive build start and dispatch from one snapshot" do
    attempt = admitted_attempt
    current = ModelCatalog.current
    current_entry = current.models.fetch("dev/mock-text").deep_dup.merge(
      "api_format" => "xai_responses",
      "model_id" => "current-wire-model",
      "wire_options" => { "responses_path" => "/current/responses" }
    )
    snapshot = ModelCatalog::Snapshot.new(
      providers: current.providers,
      models: current.models.merge("dev/mock-text" => current_entry),
      selectors: current.selectors
    ).freeze
    reads = 0
    request = nil
    quality_profiles = []
    classifier = SimpleInference::FinishQuality.method(:for)

    SimpleInference::FinishQuality.stub(
      :for,
      ->(adapter_profile:, detail:) do
        quality_profiles << adapter_profile
        classifier.call(adapter_profile: adapter_profile, detail: detail)
      end
    ) do
      ModelCatalog.stub(:current, -> { reads += 1; snapshot }) do
        fake_dispatch(sse_incomplete("hi")) do |adapter|
          ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
          request = adapter.requests.sole
        end
      end
    end

    assert_equal 1, reads
    wire_body = JSON.parse(request.fetch(:body))
    assert_equal "current-wire-model", wire_body.fetch("model"),
      "Build must use the current model pin"
    assert_equal false, wire_body.fetch("store"),
      "Dispatch must use the current xAI adapter rather than the frozen OpenAI adapter"
    assert_equal "#{snapshot.providers.fetch("dev").fetch("base_url")}/current/responses",
      request.fetch(:url), "Dispatch must use current wire options"

    receipt = UsageRecord.find_by!(
      model_invocation_public_id: attempt.model_invocation.public_id
    )
    assert_equal "current-wire-model", receipt.wire_model_id
    assert_includes quality_profiles, "xai_responses"
    assert_not_includes quality_profiles, "openai_responses",
      "ApplyResult must use the profile that parsed this send"
  end

  # THE GPT-6 API ROWS ASK FOR EVERY TURN'S REASONING: the send is the one production path that reads
  # a row's `default_context`, so the shipped row's fact reaches the wire beside the resolved effort —
  # under the service's own default earlier turns' items would not be rendered and the prefix would
  # break at every turn. When reasoning is disabled, no context rides.
  test "a row's default reasoning context rides the wire beside the effort, and never with reasoning disabled" do
    @account.update!(cost_unit: "USD")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "placeholder-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "openai_api", expected_lock_version: nil)

    sent = [true, false].to_h do |enabled|
      attempt = admitted_attempt(model: "openai_api/gpt-6-luna", reasoning_effort: "medium", reasoning_enabled: enabled)
      fake_dispatch(sse_success("hi")) do |adapter|
        ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
        [enabled, JSON.parse(adapter.requests.sole.fetch(:body))]
      end
    end

    assert_equal({ "effort" => "medium", "context" => "all_turns" }, sent.fetch(true)["reasoning"].except("summary"))
    assert_nil sent.fetch(false).dig("reasoning", "context")
  end

  test "a currently disabled provider terminalizes before provider IO" do
    attempt = admitted_attempt
    ModelProviderConfig.find_by!(account: @account, provider_id: "dev").update!(enabled: false)

    assert_pre_io_refusal(attempt, :provider_disabled, catalog: ModelCatalog.current)
  end

  test "a model missing from the current catalog terminalizes before provider IO" do
    attempt = admitted_attempt
    current = ModelCatalog.current
    catalog = ModelCatalog::Snapshot.new(
      providers: current.providers,
      models: current.models.except("dev/mock-text"),
      selectors: current.selectors
    ).freeze

    assert_pre_io_refusal(attempt, :unknown_model, catalog: catalog)
  end

  test "a current model that serves another workload terminalizes before provider IO" do
    attempt = admitted_attempt
    current = ModelCatalog.current
    embedding = current.models.fetch("dev/mock-embedding").merge(
      "model_id" => "current-embedding"
    )
    catalog = ModelCatalog::Snapshot.new(
      providers: current.providers,
      models: current.models.merge("dev/mock-text" => embedding),
      selectors: current.selectors
    ).freeze

    assert_pre_io_refusal(attempt, :unsupported_workload, catalog: catalog)
  end

  test "the settled sink hears the stream before the terminal flip" do
    attempt = admitted_attempt
    calls = []
    sink = ModelInvocations::StreamSink.new
    sink.define_singleton_method(:on_stream_settled) do |invocation|
      calls << [:settled, invocation.reload.status]
    end

    fake_dispatch(sse_success("hi")) do
      ModelInvocations::ExecuteAttempt.call(
        attempt: attempt, host: "solid_queue",
        stream_sink: sink
      )
    end

    assert_equal [[:settled, "running"]], calls,
      "the pending tail must land while the delta gate still accepts"
    assert_equal "completed", attempt.reload.status
  end

  # The runner host's cut is a fiber raise, and its tick judges by the
  # PARENT's status — which this very attempt flips. `settled:` is the
  # in-process fact the host reads instead: fired once the stream has said
  # its last word (after the sink's settle, before the flip), so a tick
  # between the settle and the post-terminal enqueues leaves the fiber be
  # and both the owner and admission wakes run.
  test "the settled hook fires before the flip and a tick between settle and wakes loses no wake" do
    attempt = admitted_attempt
    calls = []
    sink = ModelInvocations::StreamSink.new
    sink.define_singleton_method(:on_stream_settled) do |invocation|
      calls << [:sink_settled, invocation.reload.status]
    end
    settled = false
    held = false
    released = false
    aborted = false
    enqueue = InferenceRequests::ConvergeTerminalEventsJob.method(:perform_later)
    hold_owner_wake = lambda do |*args|
      held = true
      sleep(0.01) until released
      enqueue.call(*args)
    end

    InferenceRequests::ConvergeTerminalEventsJob.stub(:perform_later, hold_owner_wake) do
      fake_dispatch(sse_success("hi")) do
        Sync do |task|
          execution = task.async do
            ModelInvocations::ExecuteAttempt.call(
              attempt: attempt, host: "model_runner", stream_sink: sink,
              settled: -> { settled = true; calls << [:settled, attempt.model_invocation.reload.status] }
            )
          rescue ModelRunner::ExecutionAborted
            aborted = true
          end

          spin_until("the owner wake to be held") { held || execution.finished? }
          # The host's tick, in miniature: the parent is terminal, so the
          # cut would fire — unless the fiber has already settled it.
          assert_equal "completed", attempt.model_invocation.reload.status
          Fiber.scheduler.raise(execution.fiber, ModelRunner::ExecutionAborted.cancel) unless settled
          released = true
          execution.wait
        end
      end
    end

    assert_not aborted, "an attempt that settled its own parent is finishing, not cut"
    assert_equal [[:sink_settled, "running"], [:settled, "running"]], calls,
      "the hook follows the sink's settle and precedes ApplyResult's flip"
    assert_equal "completed", attempt.reload.status
    wakes = enqueued_jobs.map { |job| job["job_class"] }
    %w[InferenceRequests::ConvergeTerminalEventsJob ModelInvocations::AdmitQueuedWorkJob].each do |job|
      assert_includes wakes, job, "#{job} is owed after a completed attempt"
    end
  end

  test "a transient failure tells the sink to retry BEFORE the row is claimable" do
    attempt = admitted_attempt
    calls = []
    sink = ModelInvocations::StreamSink.new
    sink.define_singleton_method(:on_retry) do |invocation|
      calls << [:retry, invocation.reload.status]
    end

    fake_dispatch(json_response(503, { "error" => { "message" => "overloaded" } })) do
      ModelInvocations::ExecuteAttempt.call(
        attempt: attempt, host: "solid_queue",
        stream_sink: sink
      )
    end

    assert_equal [[:retry, "running"]], calls,
      "under Retry-After: 0 a marker after the requeue commit can lose to the next ordinal"
    assert_equal "queued", attempt.model_invocation.reload.status
  end

  test "a transient requeue wakes admission exactly when its cooldown expires (re-audit)" do
    attempt = admitted_attempt

    fake_dispatch(json_response(503, { "error" => { "message" => "overloaded" },
      "retry_after" => nil })) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
    end

    wake = enqueued_jobs.find { |job| job["job_class"] == "ModelInvocations::AdmitQueuedWorkJob" }
    assert_not_nil wake, "the predecessor honored the cooldown to the second; so do we"
    expected = attempt.model_invocation.reload.next_admission_at
    assert_not_nil expected
    assert_in_delta expected.to_f, Time.iso8601(wake.fetch("scheduled_at")).to_f, 1.0,
      "the wake is scheduled AT next_admission_at, not immediately"
  end

  test "a terminal answer wakes admission to refill the freed capacity (re-audit)" do
    attempt = admitted_attempt

    fake_dispatch(sse_success("done")) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
    end

    wake = enqueued_jobs.find { |job| job["job_class"] == "ModelInvocations::AdmitQueuedWorkJob" }
    assert_not_nil wake, "a terminal frees provider/user capacity; the minute floor is too late"
    assert_nil wake[:at], "the refill wake is immediate"
  end

  # THE FLOOR'S WAKE (the provider admission floor, 2026-09-15): the
  # terminal arm's admission kick lands at the provider's floor when the
  # terminal arrived with one, now otherwise; the requeue arm already
  # wakes at `next_admission_at`, which IS the floor, and wakes once.
  def budget_spent_attempt
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

  def admission_wakes = enqueued_jobs.select { |job| job["job_class"] == "ModelInvocations::AdmitQueuedWorkJob" }

  test "a budget spent on a 429 with Retry-After wakes admission at the provider's floor" do
    attempt = budget_spent_attempt

    fake_dispatch(json_response(429, { "error" => { "message" => "slow down" } },
                                headers: { "retry-after" => "40" })) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
    end

    assert_equal "failed", attempt.model_invocation.reload.status
    floor = ModelProviderRuntimeState.find_by!(
      account_id: attempt.model_invocation.account_id, provider_id: attempt.model_invocation.provider_id
    ).next_admission_at
    wakes = admission_wakes
    assert_equal 1, wakes.length
    assert_in_delta floor.to_f, Time.iso8601(wakes.fetch(0).fetch("scheduled_at")).to_f, 1.0,
      "a pass now would find the lane held; the siblings wake when the provider said"
  end

  test "a budget spent without Retry-After wakes admission now" do
    attempt = budget_spent_attempt

    fake_dispatch(json_response(503, { "error" => { "message" => "still down" } })) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
    end

    wakes = admission_wakes
    assert_equal 1, wakes.length
    assert_nil wakes.fetch(0)[:at], "no floor, no wait: the refill wake is immediate"
  end

  test "a requeue under Retry-After wakes admission once, at next_admission_at" do
    attempt = admitted_attempt

    fake_dispatch(json_response(429, { "error" => { "message" => "slow down" } },
                                headers: { "retry-after" => "25" })) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
    end

    wakes = admission_wakes
    assert_equal 1, wakes.length, "the requeue arm's wake is the floor's wake; no second enqueue"
    expected = attempt.model_invocation.reload.next_admission_at
    assert_in_delta expected.to_f, Time.iso8601(wakes.fetch(0).fetch("scheduled_at")).to_f, 1.0
  end

  # A DECLINED ANSWER IS WITHDRAWN, NOT SETTLED: the partial it streamed is
  # discarded from storage, so a follower is told to discard it too — while
  # the row is still running, before ApplyResult commits the terminal flip.
  test "a refused stream tells the sink to withdraw it instead of settling it" do
    attempt = admitted_attempt
    calls = []
    sink = ModelInvocations::StreamSink.new
    sink.define_singleton_method(:on_refused) { |invocation| calls << [:refused, invocation.reload.status] }
    sink.define_singleton_method(:on_stream_settled) { |_invocation| calls << :settled }

    fake_dispatch(sse_refused("I can't help with that.", text: "Sure, here")) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue", stream_sink: sink)
    end

    assert_equal [[:refused, "running"]], calls
    assert_equal "refused", attempt.model_invocation.reload.finish_quality
  end

  # The one-shot replay a follower reads after the same stream: the delta
  # that went out, then the rollback that withdraws it — never a final
  # `text_delta` the result then contradicts.
  test "a one-shot's replay after a refused stream rolls the partial back" do
    attempt = admitted_attempt
    sink = InferenceRequestEvents::StreamSink.new(attempt: attempt, flush_interval_ms: 0)

    fake_dispatch(sse_refused("I can't help with that.", text: "Sure, here")) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue", stream_sink: sink)
    end

    items = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id).order(:sequence)
    assert_equal %w[text_delta rollback], items.map(&:item_type)
    assert_equal "refused", items.last.payload.fetch("reason")
  end

  # A FAILED ATTEMPT HOLDS NONE OF WHAT IT STREAMED: the apply stores no
  # answer for a failure, so a follower drops the partial rather than keep
  # text the row will never hold — the pending tail is withdrawn, never
  # flushed, as a declined answer's is (the receipt keeps the billing).
  test "a terminal failure withdraws the pending tail instead of narrating it" do
    attempt = admitted_attempt
    frames = [
      %(data: {"type":"response.output_text.delta","delta":"kept"}\n\n),
      %(data: {"type":"response.output_text.delta","delta":" tail"}\n\n),
      %(data: {"type":"response.failed","response":{"id":"r1","status":"failed","error":{"code":"server_error","message":"boom"}}}\n\n),
    ]
    sink = InferenceRequestEvents::StreamSink.new(attempt: attempt, flush_interval_ms: 100,
      clock: -> { 0.0 })

    fake_dispatch({ sse: frames, status: 200,
                    headers: { "content-type" => "text/event-stream" } }) do
      ModelInvocations::ExecuteAttempt.call(
        attempt: attempt, host: "solid_queue",
        stream_sink: sink
      )
    end

    assert_equal "failed", attempt.model_invocation.reload.status
    items = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id)
      .where(item_type: %w[text_delta rollback]).order(:sequence)
    assert_equal [["text_delta", "kept"], ["rollback", nil]], items.map { |item| [item.item_type, item.payload["text"]] },
      "what streamed is withdrawn and the buffered tail never lands: the failed row holds none of it"
  end

  test "a transient failure on the last budgeted attempt settles instead of retrying" do
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
    attempt = ModelInvocationAttempt.create!(
        account: @account, model_invocation: invocation, ordinal: 3,
        admission_shape: "admitted_free", deadline_at: 10.minutes.from_now,
        consumer_public_id: first.consumer_public_id, payer_public_id: first.payer_public_id
    )
    calls = []
    sink = ModelInvocations::StreamSink.new
    sink.define_singleton_method(:on_retry) { |_i| calls << :retry }
    sink.define_singleton_method(:on_stream_settled) { |_i| calls << :settled }
    sink.define_singleton_method(:on_failed) { |_i| calls << :failed }

    fake_dispatch(json_response(503, { "error" => { "message" => "still down" } })) do
      ModelInvocations::ExecuteAttempt.call(
        attempt: attempt, host: "solid_queue",
        stream_sink: sink
      )
    end

    assert_equal [:failed], calls, "no retry follows a spent budget, and what streamed is withdrawn"
    assert_equal "failed", invocation.reload.status
  end

  # The host's abort is not a sink failure: it can surface inside a sink
  # call (the append's DB IO is a suspension point) and it must unwind to
  # the host, or a cut stream keeps billing and a shutdown fiber cannot die.
  test "the host's abort unwinds through the sink guard" do
    attempt = admitted_attempt
    sink = ModelInvocations::StreamSink.new
    sink.define_singleton_method(:on_event) { |*_| raise ModelRunner::ExecutionAborted.cancel }

    assert_raises(ModelRunner::ExecutionAborted) do
      fake_dispatch(sse_success("hi")) do
        ModelInvocations::ExecuteAttempt.call(
          attempt: attempt, host: "solid_queue",
          stream_sink: sink
        )
      end
    end

    assert_not_equal "completed", attempt.reload.status,
      "a swallowed abort finished the answer the host was told to stop paying for"
  end

  # Narration is auxiliary: a sink failure costs the narration, never the
  # billed answer (the recorded deviation from the predecessor's
  # fail-the-invocation flush contract).
  test "a raising sink goes quiet and the answer still applies" do
    attempt = admitted_attempt
    sink = ModelInvocations::StreamSink.new
    sink.define_singleton_method(:on_event) { |*_| raise "sink exploded" }
    settled = []
    sink.define_singleton_method(:on_stream_settled) { |_i| settled << true }

    fake_dispatch(sse_success("the answer")) do
      ModelInvocations::ExecuteAttempt.call(
        attempt: attempt, host: "solid_queue",
        stream_sink: sink
      )
    end

    attempt.reload
    assert_equal "completed", attempt.status, "the provider result outranks its replay copy"
    assert_equal "settled", attempt.settlement_state, "and the receipt landed"
    assert_empty settled, "a failed sink stays quiet for the rest of the execution"
  end

  private

    def assert_pre_io_refusal(attempt, reason, catalog:)
      ModelCatalog.stub(:current, catalog) do
        ModelInvocations::ExecutionAdapter.stub(
          :for, ->(*) { flunk "a current-catalog refusal reached provider IO" }
        ) do
          ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
        end
      end

      attempt.reload
      assert_not_predicate attempt, :started?
      assert_equal "failed", attempt.status
      invocation = attempt.model_invocation.reload
      assert_equal "failed", invocation.status
      assert_equal reason.to_s, invocation.failure_reason_key
    end
end
