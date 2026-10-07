require "test_helper"
require "test_helpers/log_capture"
require "test_helpers/invocation_result_test_helper"

# A ONE-SHOT A PROVIDER'S CLASSIFIER DECLINED RUNS ONCE MORE ON THE MODEL ITS
# CREATOR DECLARED. The terminal converger decides it — once, under the
# aggregate's lock, while the run still reads `running` — and mints the
# second invocation behind Create's own gates re-read at that moment: a
# live aggregate in a writable workspace, a creator who still stands, a
# fallback the account can run for this request and an input it can take.
# The declined partial is withdrawn from the replay, the declined call's
# terminal says where the run went instead of what it came to, and the run
# reads the latest execution. A content block is never re-sent, a fallback
# declined in turn stands, and a stop in the window wins over the switch.
class InferenceRequests::RefusalFallbackTest < ActiveJob::TestCase
  include InvocationResultTestHelper
  include LogCapture

  SWITCH = { "from" => "dev/mock-text", "to" => "dev/mock-unmetered", "reason" => "model_refused" }.freeze

  setup do
    @agent = users(:agent)
    declare!(fallback_model: "dev/mock-unmetered")
  end

  test "a declined one-shot runs once more on its creator's fallback, the declined partial withdrawn" do
    attempt = admitted_attempt(creator: @agent)
    refused = attempt.model_invocation
    inference_request = refused.inference_request
    stream(attempt, sse_refused("I can't help with that.", text: "Sure, here"))
    assert_equal "running", inference_request.reload.status, "the converger has not decided yet"

    lines = capture_log do
      assert_enqueued_with(job: ModelInvocations::AdmitQueuedWorkJob) { converge!(refused) }
    end

    invocations = ModelInvocation.where(inference_request_id: inference_request.id).order(:id).to_a
    assert_equal 2, invocations.length, "the converger minted the fallback"
    fallback = invocations.last
    assert_equal ["inference_request:#{inference_request.public_id}:2", "queued", "dev", "mock-unmetered", @agent.id],
      fallback.values_at(:internal_creation_key, :status, :provider_id, :model_ref, :creating_user_id)
    assert_equal inference_request.content_bodies.find_by(role: "input").entry_payloads,
      fallback.content_bodies.find_by(role: "request").entry_payloads, "the sealed input, asked again"
    assert_predicate fallback.content_bodies.find_by(role: "request"), :sealed?
    assert_equal({ "kind" => "inference_request", "tier" => "5m", "tail" => true }, fallback.request_options.fetch("prompt_cache"),
      "the second execution is minted a InferenceRequest's request too")
    assert_not_nil refused.reload.terminal_event_recorded_at
    assert_equal 0, InferenceRequests::ConvergeTerminalEvents.call(invocation_id: refused.id)[:recorded],
      "the declined call left the frontier with its decision"

    assert_equal "queued", inference_request.reload.status, "the run reads its latest execution"
    projection = AgentAPI::InferenceRequestPresenter.full(inference_request)
    assert_equal ["dev", "mock-unmetered"], projection.fetch(:model).values_at(:provider_id, :model_ref)
    assert_not projection.key?(:result), "no result while the fallback runs"
    assert_equal fallback.id, InferenceRequest.where(id: inference_request.id).includes(:model_invocation).sole.model_invocation.id,
      "a preloaded list reads the latest execution too"
    assert_equal ["event=model_fallback inference_request=#{inference_request.public_id} from=dev/mock-text " \
                  "to=dev/mock-unmetered reason=model_refused\n"], lines.grep(/event=model_fallback/)

    stream(admit(fallback), sse_success("the fallback's answer"))
    converge!(fallback)

    assert_equal "completed", inference_request.reload.status
    result = AgentAPI::InferenceRequestPresenter.full(inference_request).fetch(:result)
    assert_equal ["completed", "Mock: the fallback's answer", SWITCH],
      result.values_at(:status, :output_text, :model_change)
    assert_nil result[:finish_quality]
    assert_nil result[:error]
    assert_equal 2, AgentAPI::InferenceRequestPresenter.full(inference_request).dig(:usage_summary, "request_count"),
      "both calls were billed"

    items = inference_request.inference_request_event_items.order(:sequence).map { |item| [item.item_type, item.payload] }
    assert_equal %w[text_delta rollback run_status usage text_delta run_status provider_output_item_completed usage result],
      items.map(&:first)
    assert_equal({ "status" => "queued", "model_change" => SWITCH }, items.fetch(2).last,
      "the declined call's terminal says where the run went, never a result")
    followed = items.each_with_object(+"") do |(type, payload), text|
      text.clear if type == "rollback"
      text << payload.fetch("text") if type == "text_delta"
    end
    assert_equal "Mock: the fallback's answer", followed, "a follower keeps only the fallback's words"
    assert_predicate InferenceRequests::Tombstone.call(inference_request: inference_request), :accepted?
  end

  # AN OVERLOADED ONE-SHOT takes the same one switch: every budgeted attempt said the provider was
  # overloaded, so the run reads `running` until the converger decides, then runs once more on the
  # creator's fallback.
  test "an overloaded one-shot reads running until decided, then runs once more on the fallback" do
    attempt = admitted_attempt(creator: @agent)
    overloaded = attempt.model_invocation
    inference_request = overloaded.inference_request
    3.times do |index|
      stream(attempt, json_response(529, { "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }))
      next if index == 2

      ModelInvocation.where(id: overloaded.id).update_all(next_admission_at: 1.second.ago)
      attempt = admit(overloaded)
    end
    assert_equal "provider_overloaded", overloaded.reload.failure_reason_key
    assert_equal "running", inference_request.reload.status, "the converger has not decided yet"

    converge!(overloaded)

    fallback = ModelInvocation.where(inference_request_id: inference_request.id).order(:id).last
    assert_equal %w[queued mock-unmetered], fallback.values_at(:status, :model_ref)
    assert_equal({ "status" => "queued", "model_change" => SWITCH.merge("reason" => "provider_overloaded") },
      inference_request.inference_request_event_items.where(item_type: "run_status").order(:sequence).last.payload)
  end

  # A stream that fails where nothing retries it — a budget spent mid-stream — is withdrawn: the
  # row holds none of it, so a follower drops what streamed rather than keep a partial.
  test "a stream that fails at a spent budget withdraws what it streamed" do
    declare!(fallback_model: nil)
    attempt = admitted_attempt(creator: @agent)
    invocation = attempt.model_invocation
    2.times do
      stream(attempt, json_response(529, { "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }))
      ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
      attempt = admit(invocation)
    end
    cut = { status: 200, headers: { "content-type" => "text/event-stream" },
            sse: [%(data: {"type":"response.output_text.delta","delta":"Sure, here"}\n\n)] }

    stream(attempt, cut)

    assert_equal "attempt_budget_spent", invocation.reload.failure_reason_key
    types = invocation.inference_request.inference_request_event_items.order(:sequence).pluck(:item_type)
    assert_equal %w[text_delta rollback], types.select { |type| %w[text_delta rollback].include?(type) },
      "the partial streamed, then was withdrawn"
  end

  test "the switch carries the provider's category, and a fallback declined in turn stands" do
    refused = refuse!(admitted_attempt(creator: @agent))
    inference_request = refused.inference_request
    converge!(refused)
    fallback = ModelInvocation.where(inference_request_id: inference_request.id).order(:id).last
    switch = SWITCH.merge("category" => "cyber")
    assert_equal({ "status" => "queued", "model_change" => switch },
      inference_request.inference_request_event_items.where(item_type: "run_status").sole.payload)

    refuse!(admit(fallback))
    converge!(fallback)

    assert_equal 2, ModelInvocation.where(inference_request_id: inference_request.id).count, "a fallback never falls back"
    assert_equal "failed", inference_request.reload.status
    result = AgentAPI::InferenceRequestPresenter.full(inference_request).fetch(:result)
    assert_equal ["failed", "refused", "cyber", { "code" => "model_refused" }, switch],
      result.values_at(:status, :finish_quality, :refusal_category, :error, :model_change)
    assert_equal Nexus::Contract.pack.fetch("inference_requests.json").fetch("model_change_projection").sort,
      result.fetch(:model_change).keys.sort, "the pack's switch is the wire's"
  end

  # Nothing is re-sent that nobody declared; a content-protection stop is
  # the provider's verdict on the content itself; and a fallback that
  # cannot take this request — here a picture a text-only model refuses —
  # is judged at the switch, never minted to fail for another reason.
  test "no declaration, a content block, or an input the fallback cannot take stands at once" do
    declare!(fallback_model: nil)
    assert_stands(refuse!(admitted_attempt(creator: @agent)))

    declare!(fallback_model: "dev/mock-unmetered")
    assert_stands(block!(admitted_attempt(creator: @agent)), quality: "blocked", category: "SPII")

    declare!(fallback_model: "dev/mock-text-only")
    assert_stands(refuse!(admit(attachment_inference_request)))

    declare!(fallback_model: "dev/mock-unmetered")
    refused = refuse!(admit(attachment_inference_request))
    converge!(refused)
    assert_equal 2, ModelInvocation.where(inference_request_id: refused.inference_request_id).count,
      "the same picture rides a fallback that takes it"
  end

  test "PDF fallback preserves native input and refuses a replacement without file capability" do
    current = ModelCatalog.current
    models = current.models.slice("dev/mock-text", "dev/mock-unmetered").transform_values do |row|
      row.merge("capabilities" => row.fetch("capabilities").merge("input_modalities" => %w[image file]))
    end
    catalog = current.with(models: current.models.merge(models))
    pdf = "%PDF-1.7\n%%EOF\n"

    ModelCatalog.stub(:current, catalog) do
      declare!(fallback_model: "dev/mock-text-only")
      refused = refuse!(admit(attachment_inference_request(bytes: pdf, filename: "input.pdf", content_type: "application/pdf")))
      assert_stands(refused)
      assert_equal ["application/pdf"], refused.content_bodies.find_by!(role: "request").content_uploads.map(&:content_type)

      declare!(fallback_model: "dev/mock-unmetered")
      refused = refuse!(admit(attachment_inference_request(bytes: pdf, filename: "input.pdf", content_type: "application/pdf")))
      converge!(refused)
      invocations = ModelInvocation.where(inference_request_id: refused.inference_request_id).order(:id).to_a
      assert_equal 2, invocations.length
      assert_equal "mock-unmetered", invocations.last.model_ref
      original = refused.content_bodies.find_by!(role: "request")
      replacement = invocations.last.content_bodies.find_by!(role: "request")
      assert_equal original.entry_payloads, replacement.entry_payloads
      assert_equal original.upload_parts.map(&:public_id), replacement.upload_parts.map(&:public_id)
    end
  end

  # Create's gates, re-read at the switch rather than assumed from the
  # create: a workspace archived in the window, a creator removed in it,
  # and the aggregate's own tombstone (no door reaches it while the run
  # reads running, so the row is written directly).
  test "an archived workspace mints nothing" do
    refused = refuse!(admitted_attempt(creator: @agent))
    workspace = refused.inference_request.workspace
    assert_equal :accepted, Workspaces::Archive.call(
      workspace: workspace, by: workspace.owner, lock_version: workspace.lock_version
    ).outcome
    assert_stands(refused)
  end

  test "a removed creator mints nothing" do
    refused = refuse!(admitted_attempt(creator: @agent))
    assert_equal :removed, @agent.remove
    assert_stands(refused)
  end

  test "a tombstoned run mints nothing" do
    refused = refuse!(admitted_attempt(creator: @agent))
    refused.inference_request.update_columns(tombstoned_at: Time.current)
    converge!(refused)
    assert_equal 1, ModelInvocation.where(inference_request_id: refused.inference_request_id).count
  end

  # The stop lands between the refusal's apply and its converge: the run
  # settles failed on the spot, no fallback is minted, and the converger
  # finds nothing left to decide. After the switch the same stop cuts the
  # fallback, like any running work.
  test "a stop in the window settles the refusal with no fallback; after the switch it cuts the fallback" do
    refused = refuse!(admitted_attempt(creator: @agent))
    inference_request = refused.inference_request

    InferenceRequests::Cancel.call(inference_request: inference_request)

    assert_not_nil refused.reload.terminal_event_recorded_at
    assert_equal "failed", inference_request.reload.status
    assert_equal({ "code" => "model_refused" }, AgentAPI::InferenceRequestPresenter.full(inference_request).dig(:result, :error))
    converge!(refused)
    assert_equal 1, ModelInvocation.where(inference_request_id: inference_request.id).count, "the stop wins over the switch"

    switched = refuse!(admitted_attempt(creator: @agent))
    converge!(switched)
    InferenceRequests::Cancel.call(inference_request: switched.inference_request)
    assert_equal ["canceled", "canceled"],
      [ModelInvocation.where(inference_request_id: switched.inference_request_id).order(:id).last.status, switched.inference_request.reload.status]
  end

  # The refusal commits while the stop is under way — after the stop looked
  # for a declined answer and before its cut: the cut skips the now-terminal
  # row, so only the settle that follows the cut, under the same aggregate
  # lock, keeps the converger from minting a fallback on a cancelled run.
  test "a refusal that lands while the stop cuts is settled by the stop, never switched" do
    attempt = admitted_attempt(creator: @agent)
    refused = attempt.model_invocation
    inference_request = refused.inference_request
    cut = ModelInvocation::Cancellation.method(:call)
    landing = ->(**arguments) { refuse!(attempt) && cut.call(**arguments) }

    ModelInvocation::Cancellation.stub(:call, landing) { InferenceRequests::Cancel.call(inference_request: inference_request) }
    converge!(refused)

    assert_equal [["completed", "refused"]],
      ModelInvocation.where(inference_request_id: inference_request.id).order(:id).pluck(:status, :finish_quality),
      "the stop wins over the switch"
    assert_not_nil refused.reload.terminal_event_recorded_at
    assert_equal "failed", inference_request.reload.status
  end

  private

    def declare!(fallback_model:)
      outcome = Users::DeclareConfiguration.call(user: @agent, tool_definitions: [], approval_mode: nil,
        approval_rules: nil, prompt_mechanism: nil, prompt_template: nil, compaction_policy: nil,
        default_model: "dev/mock-text", fallback_model: fallback_model)
      assert_equal :declared, outcome.outcome, outcome.user.errors.full_messages.inspect
    end

    # The streamed path a runner takes: the one-shot's own sink narrates it.
    def stream(attempt, behaviour)
      sink = InferenceRequestEvents::StreamSink.new(attempt: attempt, flush_interval_ms: 0)
      fake_dispatch(behaviour) do
        ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue", stream_sink: sink)
      end
    end

    def admit(invocation)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find { _1.invocation.id == invocation.id }
      raise "not admitted" if admitted.nil?

      clear_enqueued_jobs
      admitted.attempt
    end

    # An attachment on the text lane, created through the door the way a
    # caller creates one, so the input is exactly what Create sealed.
    def attachment_inference_request(bytes: png_bytes, filename: "picture.png", content_type: "image/png")
      upload = @account.content_uploads.create!(
        creating_user: @agent,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: filename, content_type: content_type, identify: false
        )
      )
      created = InferenceRequests::Create.call(port: DevModelLane.port, command: InferenceRequests::Create::Command.new(
        workspace: workspaces(:shared), creating_user: @agent, workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation"), configuration: {},
        input: [{ "role" => "user", "parts" => [
          { "type" => "text", "text" => "what is this" },
          { "type" => "upload", "upload_public_id" => upload.public_id },
        ] }],
        upload_public_ids: [upload.public_id], billing_subject: nil, idempotency_key: SecureRandom.uuid
      ))
      assert_predicate created, :created?
      InferenceRequest.find_by!(public_id: created.accepted.fetch("inference_request_public_id")).model_invocation
    end

    # The Anthropic shape: the lane whose refusal names its category.
    def refuse!(attempt)
      refused = SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "id" => "msg_1", "content" => [], "stop_reason" => "refusal",
          "stop_details" => { "category" => "cyber", "explanation" => "The request asked for an exploit." },
          "usage" => { "input_tokens" => 2, "output_tokens" => 0 },
        }))
      ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
      apply_provider_result(attempt, refused, adapter_profile: "anthropic_messages")
      attempt.model_invocation.reload
    end

    # A Gemini content-protection stop: the lane that types BLOCKED.
    def block!(attempt)
      blocked = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "candidates" => [{ "content" => { "parts" => [{ "text" => "partial" }] }, "finishReason" => "SPII" }],
          "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 1, "totalTokenCount" => 4 },
        }))
      ).create(model: "gemini-3.8-flash", input: "Hello")
      apply_provider_result(attempt, blocked, adapter_profile: "gemini_generate_content")
      attempt.model_invocation.reload
    end

    def converge!(invocation)
      InferenceRequests::ConvergeTerminalEvents.call(invocation_id: invocation.id)
    end

    def assert_stands(refused, quality: "refused", category: "cyber")
      converge!(refused)
      inference_request = refused.inference_request.reload

      assert_equal 1, ModelInvocation.where(inference_request_id: inference_request.id).count, "nothing asked again"
      assert_equal "failed", inference_request.status
      result = AgentAPI::InferenceRequestPresenter.full(inference_request).fetch(:result)
      assert_equal ["failed", quality, category, { "code" => "model_refused" }],
        result.values_at(:status, :finish_quality, :refusal_category, :error)
      assert_not result.key?(:model_change)
    end
end
