require "json"
require "test_helper"
# NEW lib file for this lane: required directly until the integrator adds it
# to simple_inference.rb (see registry_integration.requires).

# xAI Responses lane conformance (register: `xai_responses.usage.v1`, xAI rows
# of the reasoning/cost/input-media contracts).
#
# Every negative / malformed / interruption fixture in this file is a
# DETERMINISTIC CONSTRUCTION derived from the frozen register facts — none of
# these payloads is claimed as a wire capture.
class TestXAIProtocol < Minitest::Test
  PROBE_SHAPED_USAGE = {
    "input_tokens" => 211,
    "input_tokens_details" => { "cached_tokens" => 128 },
    "output_tokens" => 19,
    "output_tokens_details" => { "reasoning_tokens" => 18 },
    "total_tokens" => 230,
    "cost_in_usd_ticks" => 3_184_000,
  }.freeze

  # --- store pin: store:false on EVERY request, never omitted, never true ---

  def test_create_always_sends_store_false_and_encrypted_reasoning_include
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    protocol.create(model: "grok-4.6", input: "Hello")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal false, body.fetch("store")
    assert_includes body.fetch("include"), "reasoning.encrypted_content"
  end


  def test_caller_store_true_is_rejected_loudly_with_zero_io
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "grok-4.6", input: "Hello", store: true)
      end

    assert_includes error.message, "store"
    assert_nil adapter.last_request, "a rejected store pin must produce zero outbound IO"
  end

  def test_caller_explicit_store_false_is_accepted
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    protocol.create(model: "grok-4.6", input: "Hello", store: false)

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal false, body.fetch("store")
  end

  def test_extra_body_store_collides_loudly
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "grok-4.6", input: "Hello", extra_body: { "store" => true })
      end

    assert_includes error.message, "store"
    assert_nil adapter.last_request
  end

  # --- stateless continuation: encrypted reasoning replay, never
  # previous_response_id / conversation (no conversation_state capability) ---

  def test_stateful_continuation_options_are_not_in_the_request_vocabulary
    keys = SimpleInference::Protocols::XAIResponses.request_option_keys

    refute_includes keys, :previous_response_id
    refute_includes keys, :conversation
    assert keys.frozen?
  end

  def test_previous_response_id_option_rejected_loudly
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "grok-4.6", input: "Hello", previous_response_id: "resp_1")
      end

    assert_includes error.message, "previous_response_id"
    assert_nil adapter.last_request
  end

  def test_extra_body_previous_response_id_rejected_loudly
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "grok-4.6", input: "Hello", extra_body: { "previous_response_id" => "resp_1" })
      end

    assert_includes error.message, "previous_response_id"
    assert_includes error.message, "encrypted"
    assert_nil adapter.last_request
  end

  def test_extra_body_conversation_rejected_loudly
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "grok-4.6", input: "Hello", extra_body: { "conversation" => "conv_1" })
      end

    assert_includes error.message, "conversation"
    assert_nil adapter.last_request
  end

  def test_encrypted_reasoning_replay_item_passes_through_verbatim
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    reasoning_item = {
      "type" => "reasoning",
      "id" => "rs_1",
      "encrypted_content" => "ENCRYPTED-BLOB",
      "summary" => [],
    }
    protocol.create(
      model: "grok-4.6",
      input: [
        reasoning_item,
        { "type" => "message", "role" => "user", "content" => [{ "type" => "input_text", "text" => "next turn" }] },
      ],
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_includes body.fetch("input"), reasoning_item
  end

  # --- reasoning effort: SDK-typed model-agnostic closed set none|low|medium|high,
  # lowered verbatim; out-of-set is loud local rejection ---

  def test_reasoning_effort_lowers_verbatim_into_nested_reasoning
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    protocol.create(model: "grok-4.6", input: "Hello", reasoning_effort: "medium")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "medium", body.fetch("reasoning").fetch("effort")
  end

  def test_every_frozen_effort_value_is_accepted
    %w[none low medium high].each do |effort|
      adapter = json_adapter
      protocol = xai_protocol(adapter: adapter)

      protocol.create(model: "grok-4.6", input: "Hello", reasoning_effort: effort)

      body = JSON.parse(adapter.last_request.fetch(:body))
      assert_equal effort, body.fetch("reasoning").fetch("effort")
    end
  end

  # `max` is a REAL effort spelling on another lane (anthropic declares it),
  # which is the point: the gate is this wire's own closed set, never a
  # family-wide vocabulary. (`xhigh` used to stand here and stopped being
  # out-of-set on 2026-08-21, when the vendor documented four levels.)
  def test_out_of_set_reasoning_effort_rejected_loudly_with_zero_io
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "grok-4.6", input: "Hello", reasoning_effort: "max")
      end

    assert_includes error.message, "max"
    assert_includes error.message, "none, low, medium, high"
    assert_nil adapter.last_request
  end

  def test_effort_case_variant_is_rejected_not_normalized
    protocol = xai_protocol(adapter: json_adapter)

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "grok-4.6", input: "Hello", reasoning_effort: "Medium")
    end
  end

  def test_reasoning_hash_effort_out_of_set_rejected
    protocol = xai_protocol(adapter: json_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "grok-4.6", input: "Hello", reasoning: { effort: "ultra" })
      end

    assert_includes error.message, "ultra"
  end

  # --- image parts. Media ingress is bytes-only (inherited Responses-family
  # policy): parts carry a SimpleInference::MediaInput and the LANE constructs
  # the base64 data-URL wire form from verified bytes. `detail` is a field of
  # the wire's input_image part and lowers verbatim beside it. ---

  # Labeled deterministic construction: PNG magic bytes.
  TINY_PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + ("\x00" * 16)).freeze

  def tiny_png_media_input
    SimpleInference::MediaInput.from_bytes(TINY_PNG_BYTES)
  end

  def test_input_image_detail_lowers_verbatim_beside_the_lane_built_data_url
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)
    media = tiny_png_media_input

    protocol.create(
      model: "grok-4.6",
      input: [
        {
          "type" => "message",
          "role" => "user",
          "content" => [
            { "type" => "input_text", "text" => "Describe this." },
            { "type" => "input_image", "image_url" => media, "detail" => "high" },
          ],
        },
      ],
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    part = body.fetch("input").fetch(0).fetch("content").fetch(1)
    assert_equal "input_image", part.fetch("type")
    assert_equal "high", part.fetch("detail")
    assert_equal "data:image/png;base64,#{[media.bytes].pack("m0")}", part.fetch("image_url")
  end

  def test_input_image_lowers_lane_constructed_data_url_from_verified_bytes
    adapter = json_adapter
    protocol = xai_protocol(adapter: adapter)
    media = tiny_png_media_input

    protocol.create(
      model: "grok-4.6",
      input: [
        {
          "type" => "message",
          "role" => "user",
          "content" => [
            { "type" => "input_text", "text" => "Describe this." },
            { "type" => "input_image", "image_url" => media },
          ],
        },
      ],
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    part = body.fetch("input").fetch(0).fetch("content").fetch(1)
    assert_equal "input_image", part.fetch("type")
    assert_equal "data:image/png;base64,#{[media.bytes].pack("m0")}", part.fetch("image_url")
  end

  def test_caller_data_uri_and_remote_url_image_parts_are_rejected_with_zero_io
    ["data:image/jpeg;base64,AAAA", "https://example.com/cat.png"].each do |carrier|
      adapter = json_adapter
      protocol = xai_protocol(adapter: adapter)

      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "grok-4.6",
          input: [
            {
              "type" => "message",
              "role" => "user",
              "content" => [{ "type" => "input_image", "image_url" => carrier }],
            },
          ],
        )
      end
      assert_nil adapter.last_request, "a rejected caller carrier must produce zero outbound IO"
    end
  end

  # --- usage: terminal-only on the pinned raw route; ticks retained losslessly;
  # absent fields stay absent (presence-vs-zero preserved) ---

  def test_usage_cost_ticks_retained_losslessly_as_integer
    adapter = json_adapter(usage: PROBE_SHAPED_USAGE)
    protocol = xai_protocol(adapter: adapter)

    result = protocol.create(model: "grok-4.6", input: "Hello")

    assert_instance_of Integer, result.usage.fetch("cost_in_usd_ticks")
    assert_equal 3_184_000, result.usage.fetch("cost_in_usd_ticks")
  end

  def test_absent_cost_in_nano_usd_stays_absent
    adapter = json_adapter(usage: PROBE_SHAPED_USAGE)
    protocol = xai_protocol(adapter: adapter)

    result = protocol.create(model: "grok-4.6", input: "Hello")

    refute result.usage.key?("cost_in_nano_usd"), "docs-only field must never be fabricated"
    assert_equal PROBE_SHAPED_USAGE, result.usage
  end

  def test_stream_result_preserves_terminal_usage_ticks
    sse = +""
    sse << sse_event({ "type" => "response.created", "response" => { "status" => "in_progress" } })
    sse << sse_event({ "type" => "response.output_text.delta", "delta" => "Hi" })
    sse << sse_event(
      {
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            { "type" => "message", "id" => "msg_1", "content" => [{ "type" => "output_text", "text" => "Hi" }] },
          ],
          "usage" => PROBE_SHAPED_USAGE,
        },
      }
    )
    sse << "data: [DONE]\n\n"

    protocol = xai_protocol(adapter: sse_adapter(sse))
    stream = protocol.stream(model: "grok-4.6", input: "Hello")
    events = stream.to_a
    result = stream.final_result

    assert_equal ["Hi"], events.grep(SimpleInference::Responses::Events::TextDelta).map(&:delta)
    assert_instance_of SimpleInference::Responses::Events::Completed, events.last
    assert_equal PROBE_SHAPED_USAGE, result.usage
    assert_instance_of Integer, result.usage.fetch("cost_in_usd_ticks")
  end

  def test_stream_tolerates_probe_observed_reasoning_summary_events
    sse = +""
    sse << sse_event({ "type" => "response.created", "response" => { "status" => "in_progress" } })
    sse << sse_event({ "type" => "response.reasoning_summary_part.added", "item_id" => "rs_1", "part" => { "type" => "summary_text", "text" => "" } })
    sse << sse_event({ "type" => "response.reasoning_summary_text.delta", "item_id" => "rs_1", "delta" => "thinking" })
    sse << sse_event({ "type" => "response.reasoning_summary_text.done", "item_id" => "rs_1", "text" => "thinking" })
    sse << sse_event({ "type" => "response.reasoning_summary_part.done", "item_id" => "rs_1" })
    sse << sse_event({ "type" => "response.output_text.delta", "delta" => "Hi" })
    sse << sse_event(
      {
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            { "type" => "message", "id" => "msg_1", "content" => [{ "type" => "output_text", "text" => "Hi" }] },
          ],
          "usage" => PROBE_SHAPED_USAGE,
        },
      }
    )
    sse << "data: [DONE]\n\n"

    protocol = xai_protocol(adapter: sse_adapter(sse))
    stream = protocol.stream(model: "grok-4.6", input: "Hello")
    events = stream.to_a
    reasoning_events = events.grep(SimpleInference::Responses::Events::ReasoningDelta)

    assert_equal ["thinking"], reasoning_events.map(&:delta)
    assert_equal ["reasoning_summary"], reasoning_events.map(&:kind)
    assert_equal ["rs_1"], reasoning_events.map(&:item_id)
    assert_equal "Hi", stream.final_result.output_text
  end

  def test_stream_interruption_before_terminal_raises
    # Deterministic interruption construction: the stream ends with no
    # terminal event and no [DONE] sentinel.
    sse = +""
    sse << sse_event({ "type" => "response.created", "response" => { "status" => "in_progress" } })
    sse << sse_event({ "type" => "response.output_text.delta", "delta" => "par" })

    protocol = xai_protocol(adapter: sse_adapter(sse))
    stream = protocol.stream(model: "grok-4.6", input: "Hello")

    error = assert_raises(SimpleInference::Error) { stream.each { |_event| nil } }
    assert_includes error.message, "ended before a terminal event"
  end

  def test_stream_response_failed_raises_with_provider_details
    sse = +""
    sse << sse_event(
      {
        "type" => "response.failed",
        "response" => { "status" => "failed", "error" => { "code" => "server_error", "message" => "provider exploded" } },
      }
    )
    sse << "data: [DONE]\n\n"

    protocol = xai_protocol(adapter: sse_adapter(sse))
    stream = protocol.stream(model: "grok-4.6", input: "Hello")

    error = assert_raises(SimpleInference::Error) { stream.each { |_event| nil } }
    assert_includes error.message, "response.failed"
    assert_includes error.message, "provider exploded"
  end

  private

  def xai_protocol(adapter:)
    SimpleInference::Protocols::XAIResponses.new(
      base_url: "https://api.x.ai",
      adapter: adapter,
    )
  end

  def json_adapter(usage: PROBE_SHAPED_USAGE)
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      define_method(:call) do |env|
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              "id" => "resp_1",
              "status" => "completed",
              "output" => [
                { "type" => "message", "id" => "msg_1", "content" => [{ "type" => "output_text", "text" => "Hi" }] },
              ],
              "usage" => usage,
            }
          ),
        }
      end
    end.new
  end

  def sse_adapter(sse)
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      define_method(:call_stream) do |env, &on_chunk|
        @last_request = env
        on_chunk.call(sse)
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
  end

  def sse_event(payload)
    "data: #{JSON.generate(payload)}\n\n"
  end
end
