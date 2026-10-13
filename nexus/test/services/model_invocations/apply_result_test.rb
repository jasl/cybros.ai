require "test_helper"
require "test_helpers/invocation_result_test_helper"
require "test_helpers/log_capture"

class ModelInvocations::ApplyResultTest < ActiveJob::TestCase
  include InvocationResultTestHelper
  include LogCapture

  # ---- success ------------------------------------------------------------

  test "a text success writes the response body and completes both rows" do
    attempt = admitted_attempt

    apply_via(attempt, sse_success("the answer"))

    attempt.reload
    assert_equal "completed", attempt.status
    assert_not_nil attempt.terminal_at
    assert_equal "settled", attempt.settlement_state, "the receipt landing settles the attempt"

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    assert_equal "completed", invocation.inference_request.status, "the InferenceRequest derives, nothing wrote it"

    body = invocation.content_bodies.find_by(role: "response")
    assert_predicate body, :sealed?
    assert_equal "Mock: the answer",
      Nexus::InputEntries.from(
        entries: body.content_body_entries.order(:position).map { _1.content_fragment.payload },
        workload: "text_generation"
      )
  end

  test "reasoning the provider showed becomes the reasoning body" do
    attempt = admitted_attempt

    apply_via(attempt, sse_success("done", reasoning: "weighing the options"))

    invocation = attempt.model_invocation.reload
    reasoning = invocation.content_bodies.find_by(role: "reasoning")
    assert_not_nil reasoning, "shown reasoning is display evidence"
    text = reasoning.content_body_entries.sole.content_fragment.payload.fetch("text")
    assert_includes text, "weighing the options"
  end

  test "Anthropic adapter reasoning becomes the reasoning body" do
    attempt = admitted_attempt
    provider_result = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com",
      api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "id" => "msg_123",
        "content" => [
          { "type" => "thinking", "thinking" => "Check the constraints.", "signature" => "sig_123" },
          { "type" => "text", "text" => "Done." },
        ],
        "stop_reason" => "end_turn",
        "usage" => {
          "input_tokens" => 2, "output_tokens" => 5,
          "output_tokens_details" => { "thinking_tokens" => 4 },
        },
      }))
    ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)

    apply_provider_result(attempt, provider_result)

    reasoning = attempt.model_invocation.reload.content_bodies.find_by!(role: "reasoning")
    assert_equal "Check the constraints.",
      reasoning.content_body_entries.sole.content_fragment.payload.fetch("text")
    receipt = receipt_for(attempt)
    assert_equal 5, receipt.output_tokens,
      "Anthropic output is already reasoning-inclusive"
    assert_equal 4, receipt.reasoning_tokens
  end

  test "Gemini adapter reasoning becomes the reasoning body" do
    attempt = admitted_attempt
    provider_result = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com",
      api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "responseId" => "resp_123",
        "candidates" => [{
          "content" => { "parts" => [
            { "thought" => true, "thoughtSignature" => "sig_123", "text" => "Check the constraints." },
            { "text" => "Done." },
          ] },
          "finishReason" => "STOP",
        }],
        "usageMetadata" => {
          "promptTokenCount" => 2,
          "candidatesTokenCount" => 3,
          "thoughtsTokenCount" => 4,
          "totalTokenCount" => 9,
        },
      }))
    ).create(model: "gemini-3.5-flash", input: "Hello")

    apply_provider_result(attempt, provider_result)

    reasoning = attempt.model_invocation.reload.content_bodies.find_by!(role: "reasoning")
    assert_equal "Check the constraints.",
      reasoning.content_body_entries.sole.content_fragment.payload.fetch("text")
  end

  # THE OTHER FAMILY'S REASONING, which is where every third-party host puts
  # it. A Responses lane emits reasoning as an output ITEM; a chat-completions
  # lane emits it on the assistant message, and the gem normalizes both of
  # that family's spellings — DeepSeek's `reasoning_content` and OpenRouter's
  # `reasoning` — onto `reasoning_content` for us.
  #
  # It had to be injected here because no fake lane in this suite speaks that
  # family, which is exactly why a live OpenRouter turn was the first thing to
  # notice: it reported what the thinking cost and kept none of it.
  test "reasoning a chat-completions lane showed becomes the reasoning body" do
    attempt = admitted_attempt
    started = start(attempt)
    built = build(attempt)
    outcome = fake_dispatch(sse_success("391")) do
      ModelInvocations::Dispatch.call(
        attempt: started.attempt, context: started.context, request: built.request
      )
    end
    result = outcome.result.with(
      output_items: [],
      assistant_message: { "role" => "assistant", "content" => "391", "reasoning_content" => "seventeen times twenty-three" }
    )
    patched = SimpleDelegator.new(outcome)
    patched.define_singleton_method(:result) { result }

    ModelInvocations::ApplyResult.call(attempt: started.attempt, outcome: patched)

    reasoning = attempt.model_invocation.reload.content_bodies.find_by(role: "reasoning")
    assert_not_nil reasoning, "shown reasoning is display evidence on every family that shows it"
    text = reasoning.content_body_entries.sole.content_fragment.payload.fetch("text")
    assert_includes text, "seventeen times twenty-three"
  end

  test "a text response with no reasoning writes no reasoning body" do
    attempt = admitted_attempt

    apply_via(attempt, sse_success("plain"))

    assert_nil attempt.model_invocation.reload.content_bodies.find_by(role: "reasoning")
  end

  # Binary outputs ride Active Storage, the predecessor's shape: reference
  # counting, purge-on-destroy and cross-model reuse come with the framework.
  test "an image success attaches the decoded bytes as output files" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")

    apply_via(attempt, json_response(200, {
      "created" => 0,
      "data" => [
        { "b64_json" => [png_bytes].pack("m0") },
        { "b64_json" => [png_bytes].pack("m0"), "revised_prompt" => "a calmer cat" },
      ],
      "usage" => { "prompt_tokens" => 1, "completion_tokens" => 0, "total_tokens" => 1 },
    }))

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    assert_equal 2, invocation.output_files.count
    assert_equal png_bytes, invocation.output_files.first.download
    body = invocation.content_bodies.find_by(role: "response")
    assert_includes body.content_body_entries.sole.content_fragment.payload.fetch("text"),
      "a calmer cat"
  end

  test "a speech success attaches the audio and writes no response body" do
    attempt = admitted_attempt(workload: "speech_generation", model: "dev/mock-speech", input: "read this")

    apply_via(attempt, { status: 200, headers: { "content-type" => "audio/wav" }, body: wav_bytes })

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    audio = invocation.output_files.sole
    assert_equal "audio/wav", audio.content_type
    assert_equal wav_bytes, audio.download
    assert_nil invocation.content_bodies.find_by(role: "response"),
      "speech has no text; an empty body would be an invented one"
  end

  # `has_many_attached:output_files, analyze::lazily` is the framework's spelling for "never analyze
  # on attach": the blob is written once with the sniffed type and no metadata claims an analysis
  # that never ran.
  test "an image output attaches without analysis and without an analyzed stamp" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image", input: "a cat")

    assert_no_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
      apply_via(attempt, json_response(200, {
        "created" => 0,
        "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 0, "total_tokens" => 1 },
      }))
    end

    blob = attempt.model_invocation.reload.output_files.sole.blob
    assert_not_includes blob.metadata, "analyzed"
    assert_not_predicate blob, :analyzed?
    assert_equal "image/png", blob.content_type
  end

  test "a speech output attaches without analysis and without an analyzed stamp" do
    attempt = admitted_attempt(workload: "speech_generation", model: "dev/mock-speech", input: "read this")

    assert_no_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
      apply_via(attempt, { status: 200, headers: { "content-type" => "audio/wav" }, body: wav_bytes })
    end

    blob = attempt.model_invocation.reload.output_files.sole.blob
    assert_not_includes blob.metadata, "analyzed"
    assert_not_predicate blob, :analyzed?
  end

  test "speech storage trusts detected audio bytes rather than the response header" do
    attempt = admitted_attempt(workload: "speech_generation", model: "dev/mock-speech", input: "read this")

    apply_via(attempt, { status: 200, headers: { "content-type" => "audio/mpeg" }, body: wav_bytes })

    audio = attempt.model_invocation.reload.output_files.sole
    assert_equal "audio/wav", audio.content_type
    assert_equal wav_bytes, audio.download
  end

  test "a speech response without detectable audio fails as unstorable" do
    attempt = admitted_attempt(workload: "speech_generation", model: "dev/mock-speech", input: "read this")

    result = apply_via(
      attempt,
      { status: 200, headers: { "content-type" => "audio/wav" }, body: "not audio" }
    )

    assert_predicate result, :applied?
    invocation = attempt.model_invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "result_unstorable", invocation.failure_reason_key
    assert_empty invocation.output_files
    assert_equal "result_unstorable", receipt_for(attempt).error_code
  end

  test "an embedding success stores the sanitized vectors as the response" do
    attempt = admitted_attempt(workload: "embedding", model: "dev/mock-embedding", input: "embed me")

    apply_via(attempt, json_response(200, {
      "object" => "list", "model" => "mock-embedding",
      "data" => [{ "object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2, 0.3] }],
      "usage" => { "prompt_tokens" => 2, "total_tokens" => 2 },
    }))

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    payload = JSON.parse(
      invocation.content_bodies.find_by(role: "response")
        .content_body_entries.sole.content_fragment.payload.fetch("text")
    )
    assert_equal [0.1, 0.2, 0.3], payload.dig("embeddings", 0, "embedding")
  end

  # TERMINAL QUALITY (Round E): the gem carries the lane's typed finish fact
  # and the classifier names it; a cut-off answer stays `completed` — it was
  # produced and billed — with the caveat recorded beside the status.
  test "an answer cut off by its output budget completes WITH a caveat" do
    attempt = admitted_attempt

    apply_via(attempt, sse_incomplete("as far as I got"))

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status,
      "the answer was produced and billed; a caveat is not a failure"
    assert_equal "output_budget_exhausted", invocation.finish_quality
    assert_nil invocation.failure_reason_key,
      "quality and failure are separate axes and never both apply"
  end

  test "an answer that ran to its natural end carries no caveat" do
    attempt = admitted_attempt

    apply_via(attempt, sse_success("all of it"))

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    assert_nil invocation.finish_quality, "absence IS the clean-finish signal"
  end

  # ---- the server's verdict on the replayed history ------------------------

  # Under a dropping thinking binding Anthropic answers 200 and names each block it dropped:
  # the list rides the trace envelope verbatim, and each entry is a warn line an operator
  # greps — a silent loss would otherwise read as a normal answer.
  test "an Anthropic answer records what the server did to the replayed thinking" do
    attempt = admitted_attempt
    dropped = { "type" => "thinking_dropped", "path" => "messages.3.content.0", "reason" => "prefix_binding_mismatch" }
    answer = anthropic_answer(
      "content" => [
        { "type" => "thinking", "thinking" => "Check the constraints.", "signature" => "sig_123" },
        { "type" => "text", "text" => "Done." },
      ],
      "input_transformations" => [dropped]
    )

    lines = capture_log { apply_provider_result(attempt, answer, adapter_profile: "anthropic_messages") }

    invocation = attempt.model_invocation
    assert_equal [dropped], trace_envelope(attempt).fetch("input_transformations")
    assert_equal ["event=provider_input_transformation invocation=#{invocation.public_id} ordinal=1 " \
                  "type=thinking_dropped path=messages.3.content.0 reason=prefix_binding_mismatch"],
      lines.grep(/event=provider_input_transformation /).map(&:strip)
    assert_equal ["event=provider_input_transformations invocation=#{invocation.public_id} ordinal=1 count=1"],
      lines.grep(/event=provider_input_transformations /).map(&:strip)
  end

  # `[]` is the provider saying the history replayed intact — a fact, never absence — so the
  # envelope is written for it even when the answer thought nothing.
  test "an intact replay records an empty list even when nothing was thought" do
    attempt = admitted_attempt
    answer = anthropic_answer(
      "content" => [{ "type" => "text", "text" => "Done." }], "input_transformations" => []
    )

    lines = capture_log { apply_provider_result(attempt, answer, adapter_profile: "anthropic_messages") }

    envelope = trace_envelope(attempt)
    assert_equal [], envelope.fetch("input_transformations")
    assert_equal [{ "kind" => "assistant_message", "ordinal" => 0 }], envelope.fetch("items"),
      "nothing was thought: the answer's place in the walk is the only item"
    assert_empty ModelReasoning::Trace.new(envelope: envelope).reasoning_items, "so nothing replays"
    assert_equal ["event=provider_input_transformations invocation=#{attempt.model_invocation.public_id} " \
                  "ordinal=1 count=0"],
      lines.grep(/event=provider_input_transformations /).map(&:strip)
    assert_empty lines.grep(/event=provider_input_transformation /)
    assert_nil attempt.model_invocation.content_bodies.find_by(role: "reasoning"),
      "the verdict is replay evidence, never display reasoning"
  end

  # THE OBSERVED STREAM (claude-opus-5-5, a changed system prompt under `drop_block`): the list
  # rides `message_start`'s message and no `message_delta` carries it. Verbatim but for the
  # opaque signature, cut short.
  OPUS_DROPPED_STREAM = <<~'JSONL'.lines.map { |line| JSON.parse(line) }.freeze
    {"type":"message_start","message":{"model":"claude-opus-5-5","id":"msg_011CfRCsfDXtv6Y4iR9HYojZ","type":"message","role":"assistant","content":[],"container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":588,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":8,"service_tier":"standard","inference_geo":"global"},"input_transformations":[{"type":"thinking_dropped","path":"messages.1.content.0","reason":"prefix_binding_mismatch"}],"diagnostics":null}}
    {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}
    {"type":"ping"}
    {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I"}}
    {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" see a.txt contains \"alpha first line\" and \"alpha second line\" — b.txt likely has similar content with \"beta\". Let me check it now."}}
    {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"CAQShQUKEAgSGAI4AUIIdGhp..."}}
    {"type":"content_block_stop","index":0}
    {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
    {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"a"}}
    {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":".txt has"}}
    {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" two l"}}
    {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ines that start with \"alpha"}}
    {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\", so I expect b.txt to follow the same pattern, maybe with lines like \"beta first line\" and \"beta second line\"."}}
    {"type":"content_block_stop","index":1}
    {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01GJB88Bxbn9Pvc7V6N2EnsB","name":"read_file","input":{},"caller":{"type":"direct"}}}
    {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}
    {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\""}}
    {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":": \""}}
    {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"b.txt\"}"}}
    {"type":"content_block_stop","index":2}
    {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null,"stop_details":null,"container":null},"usage":{"input_tokens":588,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":151,"output_tokens_details":{"thinking_tokens":47}}}
    {"type":"message_stop"}
  JSONL

  test "a streamed Anthropic answer carries the same fact through the assembled message" do
    attempt = admitted_attempt
    frames = OPUS_DROPPED_STREAM.map { |event| "event: #{event.fetch("type")}\ndata: #{JSON.generate(event)}\n\n" }
    stream = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(
        { sse: frames, status: 200, headers: { "content-type" => "text/event-stream" } }
      )
    ).stream(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
    stream.each { }

    apply_provider_result(attempt, stream.final_result, adapter_profile: "anthropic_messages")

    assert_equal [{ "type" => "thinking_dropped", "path" => "messages.1.content.0", "reason" => "prefix_binding_mismatch" }],
      trace_envelope(attempt).fetch("input_transformations"),
      "exactly the one entry the wire sent — never doubled by the delta"
  end

  test "a provider that reports no transformations writes no such fact" do
    attempt = admitted_attempt

    lines = capture_log { apply_via(attempt, sse_success("done", reasoning: "w", reasoning_encrypted: "e")) }

    envelope = trace_envelope(attempt)
    assert_not envelope.key?("input_transformations"), "unknown is not intact"
    assert_empty lines.grep(/provider_input_transformation/)
  end

  test "a hostile entry costs its own tail, never a second log line" do
    attempt = admitted_attempt
    hostile = { "type" => "thinking_dropped", "path" => "a\nb" + "x" * 300, "reason" => "prefix_binding_mismatch" }
    answer = anthropic_answer(
      "content" => [{ "type" => "text", "text" => "Done." }], "input_transformations" => [hostile]
    )

    lines = capture_log { apply_provider_result(attempt, answer, adapter_profile: "anthropic_messages") }

    assert_equal ["event=provider_input_transformation invocation=#{attempt.model_invocation.public_id} " \
                  "ordinal=1 type=thinking_dropped path=a_b#{"x" * 125} reason=prefix_binding_mismatch"],
      lines.grep(/event=provider_input_transformation /).map(&:strip)
    assert_equal [hostile], trace_envelope(attempt).fetch("input_transformations"),
      "the log line is bounded; the evidence is verbatim"
  end

  # The verdict is the provider's JSON, read after the answer committed: a value that is not a
  # list is no verdict at all, and an entry that is not an object is still an entry, logged with
  # no fields. Neither may raise, or the owner's wake and the admission kick behind the apply
  # never run.
  test "a verdict that is not a list is no verdict, and an entry that is not an object is logged bare" do
    ["dropped", { "path" => "messages.1.content.0" }].each do |malformed|
      attempt = admitted_attempt
      answer = anthropic_answer(
        "content" => [{ "type" => "text", "text" => "Done." }], "input_transformations" => malformed
      )

      applied = nil
      lines = capture_log do
        applied = apply_provider_result(attempt, answer, adapter_profile: "anthropic_messages")
      end

      assert_predicate applied, :applied?
      assert_equal "completed", attempt.model_invocation.reload.status
      assert_not trace_envelope(attempt).key?("input_transformations"), "#{malformed.inspect} names nothing"
      assert_empty lines.grep(/provider_input_transformation/)
    end

    attempt = admitted_attempt
    answer = anthropic_answer(
      "content" => [{ "type" => "text", "text" => "Done." }], "input_transformations" => [1]
    )
    applied = nil
    lines = capture_log { applied = apply_provider_result(attempt, answer, adapter_profile: "anthropic_messages") }

    assert_predicate applied, :applied?
    assert_equal [1], trace_envelope(attempt).fetch("input_transformations"), "the evidence stays verbatim"
    invocation = attempt.model_invocation
    assert_equal ["event=provider_input_transformations invocation=#{invocation.public_id} ordinal=1 count=1",
                  "event=provider_input_transformation invocation=#{invocation.public_id} ordinal=1 " \
                  "type= path= reason="],
      lines.grep(/event=provider_input_transformations? /).map(&:strip)
  end

  # ---- the storability and byte-safety edges ------------------------------

  # A deterministic bound refusal is the invocation FAILING, never an
  # exception into a job retry that re-delivers the same refusal while the
  # attempt strands running until the sweep calls delivered work timed-out.
  test "an unstorable result fails the invocation instead of raising" do
    attempt = admitted_attempt

    result = apply_via(attempt, sse_success("x" * 1_100_000))

    assert_predicate result, :applied?
    invocation = attempt.model_invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "result_unstorable", invocation.failure_reason_key
    assert_equal "failed", attempt.reload.status
    receipt = receipt_for(attempt)
    assert_equal "failed", receipt.status
    assert_equal "result_unstorable", receipt.error_code
  end

  # One bad image costs that image, never the whole apply — and RFC 2045
  # line-wrapped base64 remains valid after its whitespace is normalized.
  test "an oversize image is skipped and its line-wrapped sibling still lands" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")
    wrapped = [png_bytes].pack("m")  # line-wrapped: strict m0 refuses it

    stub_const(ModelInvocations::ApplyResult, :MAX_IMAGE_OUTPUT_BYTES, png_bytes.bytesize) do
      apply_via(attempt, json_response(200, {
        "data" => [
          { "b64_json" => [png_bytes * 3].pack("m0") },
          { "b64_json" => wrapped },
        ],
      }))
    end

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    assert_equal 1, invocation.output_files.count, "the bounded image survives its oversize sibling"
    assert_equal png_bytes, invocation.output_files.sole.download
  end

  test "a malformed image is skipped without costing its sibling or revised prompt" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")

    apply_via(attempt, json_response(200, {
      "data" => [
        { "b64_json" => "%%%" },
        { "b64_json" => [png_bytes].pack("m0"), "revised_prompt" => "the usable image" },
      ],
    }))

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    assert_equal 1, invocation.output_files.count
    assert_equal png_bytes, invocation.output_files.sole.download
    response = invocation.content_bodies.find_by!(role: "response")
    assert_includes response.content_body_entries.sole.content_fragment.payload.fetch("text"),
      "the usable image"
  end

  test "declared image MIME cannot turn non-image bytes into an output" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")

    apply_via(attempt, json_response(200, {
      "data" => [
        { "b64_json" => ["not an image"].pack("m0"), "mime_type" => "image/png" },
        { "b64_json" => [png_bytes].pack("m0") },
      ],
    }))

    files = attempt.model_invocation.reload.output_files
    assert_equal 1, files.count
    assert_equal png_bytes, files.sole.download
  end

  test "image storage uses the byte-detected MIME when the provider label disagrees" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")
    jpeg = "\xFF\xD8\xFFpayload".b

    apply_via(attempt, json_response(200, {
      "data" => [{ "b64_json" => [jpeg].pack("m0"), "mime_type" => "image/png" }],
    }))

    image = attempt.model_invocation.reload.output_files.sole
    assert_equal "image/jpeg", image.content_type
    assert_equal jpeg, image.download
  end

  test "an image response with no detectable image fails as unstorable" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")

    result = apply_via(attempt, json_response(200, {
      "data" => [{ "b64_json" => ["not an image"].pack("m0"), "mime_type" => "image/png" }],
    }))

    assert_predicate result, :applied?
    invocation = attempt.model_invocation.reload
    assert_equal "failed", invocation.status
    assert_equal "result_unstorable", invocation.failure_reason_key
    assert_empty invocation.output_files
    assert_equal "result_unstorable", receipt_for(attempt).error_code
  end

  test "a later image staging failure purges already-created sibling blobs" do
    attempt = admitted_attempt(workload: "image_generation", model: "dev/mock-image")
    create_and_upload = ActiveStorage::Blob.method(:create_and_upload!)
    first_blob = nil
    calls = 0

    error = assert_raises(RuntimeError) do
      ActiveStorage::Blob.stub(:create_and_upload!, lambda { |**attributes|
        calls += 1
        raise "second image staging failed" if calls == 2

        first_blob = create_and_upload.call(**attributes)
      }) do
        apply_via(attempt, json_response(200, {
          "data" => [
            { "b64_json" => [png_bytes].pack("m0") },
            { "b64_json" => [png_bytes].pack("m0") },
          ],
        }))
      end
    end

    assert_equal "second image staging failed", error.message
    assert_not ActiveStorage::Blob.exists?(first_blob.id),
      "a partial output array must not escape the exception cleanup"
  end

  test "transcription text becomes the response body" do
    attempt = admitted_attempt(
      workload: "transcription", model: "dev/mock-transcription", input: "a hint",
      upload: { media_type: "audio/wav", bytes: "RIFF\x00\x00\x00\x00WAVEfmt probe".b }
    )

    apply_via(attempt, json_response(200, { "text" => "the spoken words" }))

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    body = invocation.content_bodies.find_by(role: "response")
    assert_equal "the spoken words",
      body.content_body_entries.sole.content_fragment.payload.fetch("text")
  end

  private

    def trace_envelope(attempt)
      attempt.model_invocation.reload.content_bodies.find_by!(role: "reasoning_trace")
        .content_body_entries.sole.content_fragment.payload
    end
end
