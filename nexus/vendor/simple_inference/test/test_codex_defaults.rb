require "json"
require "test_helper"

# Pins the Codex Responses wire contract (register `codex_responses.usage.v1`
# + the codex reasoning-contract row). Every negative/malformed/terminal
# payload below is a deterministic construction mirroring the register's
# pinned codex-rs facts — none of them is a wire capture.
#
# The Responses-Lite reshape is CONSTRUCTOR-DRIVEN: the format's wire_options
# carry `use_responses_lite: true` and ApiFormat.protocol_for forwards it as a
# protocol construction option. Model-name regex dispatch is dead.
class TestCodexDefaults < Minitest::Test
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze

  def test_create_posts_stream_true_to_short_responses_path
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    protocol.create(model: "gpt-5-codex", input: "Hello")

    env = adapter.last_request
    assert_equal :post, env.fetch(:method)
    assert_equal "http://example.com/responses", env.fetch(:url)

    body = JSON.parse(env.fetch(:body))
    assert_equal "gpt-5-codex", body.fetch("model")
    assert_equal true, body.fetch("stream")
  end

  def test_create_normalizes_string_input_into_message_items
    body = wire_body_for_create

    expected_input = [
      {
        "type" => "message",
        "role" => "user",
        "content" => [{ "type" => "input_text", "text" => "Hello" }],
      },
    ]
    assert_equal expected_input, body.fetch("input")
  end

  def test_create_forces_store_false_when_caller_omits_store
    body = wire_body_for_create

    assert_equal false, body.fetch("store")
  end

  def test_create_lets_caller_override_store_to_true
    body = wire_body_for_create(store: true)

    assert_equal true, body.fetch("store")
  end

  # The codex CLI sends include:["reasoning.encrypted_content"] only when the
  # request carries a reasoning object (codex-rs client.rs); without reasoning
  # it sends no include at all.
  def test_create_defaults_include_to_encrypted_content_when_reasoning_requested
    body = wire_body_for_create(reasoning: { effort: "low" })

    assert_equal ["reasoning.encrypted_content"], body.fetch("include")
  end

  def test_create_defaults_include_for_the_flat_reasoning_effort_spelling
    body = wire_body_for_create(reasoning_effort: "low")

    assert_equal ["reasoning.encrypted_content"], body.fetch("include")
  end

  def test_create_omits_include_default_without_reasoning
    body = wire_body_for_create

    refute_includes body, "include"
  end

  def test_create_keeps_caller_include_untouched_without_reasoning
    body = wire_body_for_create(include: ["message.output_text.logprobs"])

    assert_equal ["message.output_text.logprobs"], body.fetch("include")
  end

  def test_create_unions_encrypted_content_into_caller_include_when_reasoning_requested
    body = wire_body_for_create(include: ["message.output_text.logprobs"], reasoning: { effort: "low" })

    assert_equal ["message.output_text.logprobs", "reasoning.encrypted_content"], body.fetch("include")
    assert_equal({ "effort" => "low" }, body.fetch("reasoning"))
  end

  # The registry-declared encrypted_reasoning_include: false must genuinely
  # suppress the include — the parent capture default once re-added it
  # unconditionally, so the false spelling was inert (closing re-audit
  # review). Shipped rows declare true, so this is the only place the false
  # path is exercised.
  def test_encrypted_reasoning_include_false_suppresses_the_include
    adapter = streaming_adapter(completed_sse)
    protocol = SimpleInference::Protocols::CodexResponses.new(
      base_url: "http://example.com", adapter:, encrypted_reasoning_include: false
    )
    protocol.create(model: "gpt-5-codex", input: "Hello", reasoning: { effort: "low" })
    body = JSON.parse(adapter.last_request.fetch(:body))

    refute_includes body, "include",
      "a false row must not emit include:[reasoning.encrypted_content] from either home"
  end

  # codex-rs codex-api/src/common.rs `#[serde(skip_serializing_if =
  # "String::is_empty")] instructions`: an empty instructions string is
  # OMITTED. The reference never sends a filler sentence, so neither does
  # this lane — a model-facing sentence is never hand-written here.
  def test_create_omits_instructions_when_absent
    body = wire_body_for_create

    refute_includes body, "instructions"
  end

  def test_create_keeps_caller_provided_instructions
    body = wire_body_for_create(instructions: "Answer in French.")

    assert_equal "Answer in French.", body.fetch("instructions")
  end

  def test_create_omits_whitespace_only_instructions
    body = wire_body_for_create(instructions: "  \n ")

    refute_includes body, "instructions"
  end

  # --- max_output_tokens: explicit inventoried disposition (locally_rejected)
  # The pinned codex-rs request struct never carries max_output_tokens; the
  # old code deleted the declared option SILENTLY, which the register's
  # request-control inventory forbids ("omission is invalid"). The declared
  # spelling is now a loud zero-IO rejection; extra_body stays the caller's
  # verbatim escape hatch.

  def test_declared_max_output_tokens_is_a_loud_local_rejection
    protocol = codex_protocol(adapter: streaming_adapter(completed_sse))

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gpt-5-codex", input: "Hello", max_output_tokens: 128)
      end

    assert_includes error.message, "max_output_tokens"
    assert_includes error.message, "extra_body"
  end

  def test_string_spelled_max_output_tokens_is_rejected_too
    protocol = codex_protocol(adapter: streaming_adapter(completed_sse))

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "gpt-5-codex", input: "Hello", **{ "max_output_tokens" => 256 })
    end
  end

  def test_request_option_keys_drop_only_max_output_tokens_from_the_parent_vocabulary
    keys = SimpleInference::Protocols::CodexResponses.request_option_keys

    refute_includes keys, :max_output_tokens
    assert_equal(
      SimpleInference::Protocols::OpenAIResponses.request_option_keys - [:max_output_tokens],
      keys,
    )
    assert keys.frozen?
  end

  def test_stream_applies_the_same_wire_defaults_as_create
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    protocol.stream(model: "gpt-5-codex", input: "Hello", reasoning_effort: "low").each { |_event| nil }

    env = adapter.last_request
    assert_equal "http://example.com/responses", env.fetch(:url)

    body = JSON.parse(env.fetch(:body))
    assert_equal true, body.fetch("stream")
    assert_equal false, body.fetch("store")
    assert_equal ["reasoning.encrypted_content"], body.fetch("include")
    refute_includes body, "instructions"
  end

  def test_stream_omits_include_default_without_reasoning
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    protocol.stream(model: "gpt-5-codex", input: "Hello").each { |_event| nil }

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute_includes body, "include"
    assert_equal false, body.fetch("store")
  end

  def test_create_normalizes_response_done_with_status_done_to_completed
    sse = sse_events(
      {
        "type" => "response.done",
        "response" => {
          "id" => "resp_123",
          "status" => "done",
          "output" => [
            { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi from codex" }] },
          ],
          "usage" => { "input_tokens" => 3, "output_tokens" => 4 },
        },
      }
    )
    adapter = streaming_adapter(sse)
    protocol = codex_protocol(adapter:)

    result = protocol.create(model: "gpt-5-codex", input: "Hello")

    assert_instance_of SimpleInference::Responses::Result, result
    assert_equal "completed", result.finish_reason
    assert_equal "resp_123", result.id
    assert_equal "hi from codex", result.output_text
    assert_equal({ "input_tokens" => 3, "output_tokens" => 4 }, result.usage)
  end

  # --- Terminal contract (deterministic constructions per the register) ---

  def test_create_raises_typed_response_failed_error_retaining_wire_usage
    sse = sse_events(
      {
        "type" => "response.failed",
        "response" => {
          "status" => "failed",
          "error" => { "code" => "server_error", "message" => "provider exploded" },
          "usage" => { "input_tokens" => 7, "output_tokens" => 0 },
        },
      }
    )
    protocol = codex_protocol(adapter: streaming_adapter(sse))

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::ResponseFailedError) do
        protocol.create(model: "gpt-5-codex", input: "Hello")
      end

    assert_includes error.message, "server_error"
    assert_includes error.message, "provider exploded"
    assert_equal "server_error", error.code
    # Presence-vs-zero: the wire carried usage on the failed terminal, so the
    # typed error retains it verbatim.
    assert_equal({ "input_tokens" => 7, "output_tokens" => 0 }, error.usage)
  end

  def test_response_failed_without_wire_usage_keeps_usage_nil
    sse = sse_events(
      {
        "type" => "response.failed",
        "response" => {
          "status" => "failed",
          "error" => { "code" => "server_error", "message" => "boom" },
        },
      }
    )
    protocol = codex_protocol(adapter: streaming_adapter(sse))

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::ResponseFailedError) do
        protocol.create(model: "gpt-5-codex", input: "Hello")
      end

    assert_nil error.usage, "absent wire usage must stay absent — never a fabricated zero hash"
  end

  # response.incomplete is a SUCCESS terminal carrying partial output + usage.
  # The old codex file raised here and destroyed the usage; the lane now
  # aligns with the parent: status kept, cutoff reason distinct, usage kept.
  def test_create_returns_incomplete_result_with_usage_retained
    sse = sse_events(
      { "type" => "response.output_text.delta", "delta" => "partial" },
      {
        "type" => "response.incomplete",
        "response" => {
          "id" => "resp_inc",
          "status" => "incomplete",
          "incomplete_details" => { "reason" => "max_output_tokens" },
          "output" => [
            { "type" => "message", "content" => [{ "type" => "output_text", "text" => "partial" }] },
          ],
          "usage" => { "input_tokens" => 15, "output_tokens" => 32, "total_tokens" => 47 },
        },
      }
    )
    protocol = codex_protocol(adapter: streaming_adapter(sse))

    result = protocol.create(model: "gpt-5-codex", input: "Hello")

    assert_equal "incomplete", result.finish_reason, "wire status enum survives, never overwritten by the reason"
    assert_equal "partial", result.output_text
    assert_equal({ "input_tokens" => 15, "output_tokens" => 32, "total_tokens" => 47 }, result.usage)
  end

  def test_responses_surfaces_incomplete_reason_as_the_distinct_field
    sse = sse_events(
      {
        "type" => "response.incomplete",
        "response" => {
          "status" => "incomplete",
          "incomplete_details" => { "reason" => "content_filter" },
          "output" => [],
          "usage" => { "input_tokens" => 2, "output_tokens" => 1 },
        },
      }
    )
    protocol = codex_protocol(adapter: streaming_adapter(sse))

    result = protocol.responses(model: "gpt-5-codex", input: "Hello", stream: true)

    assert_equal "content_filter", result.incomplete_reason
    assert_equal({ "input_tokens" => 2, "output_tokens" => 1 }, result.usage)
  end

  # --- usage_not_included: typed entitlement/usage-limit failure ---
  # Register: SSE matches error.code == "usage_not_included" inside
  # response.failed; the non-SSE bridge matches error.error_type ==
  # "usage_not_included" on HTTP 429. Both are the typed UsageNotIncluded
  # failure — never a successful missing-usage marker.

  def test_sse_usage_not_included_inside_response_failed_raises_the_typed_error
    sse = sse_events(
      {
        "type" => "response.failed",
        "response" => {
          "status" => "failed",
          "error" => { "code" => "usage_not_included", "message" => "plan limit reached" },
        },
      }
    )
    protocol = codex_protocol(adapter: streaming_adapter(sse))

    error =
      assert_raises(SimpleInference::Protocols::CodexResponses::UsageNotIncludedError) do
        protocol.create(model: "gpt-5-codex", input: "Hello")
      end

    assert_kind_of SimpleInference::Protocols::OpenAIResponses::ResponseFailedError, error
    assert_equal "usage_not_included", error.code
    assert_includes error.message, "usage_not_included"
    assert_includes error.message, "plan limit reached"
  end

  def test_http_429_usage_not_included_error_type_raises_the_typed_error
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_request)
          {
            status: 429,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              { "error" => { "error_type" => "usage_not_included", "message" => "no usage in plan" } }
            ),
          }
        end
      end.new
    protocol = codex_protocol(adapter:)

    error =
      assert_raises(SimpleInference::Protocols::CodexResponses::UsageNotIncludedError) do
        protocol.create(model: "gpt-5-codex", input: "Hello")
      end

    assert_equal "usage_not_included", error.code
    assert_includes error.message, "no usage in plan"
    assert_nil error.usage
  end

  def test_http_429_without_the_marker_stays_a_plain_http_error
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_request)
          {
            status: 429,
            headers: { "content-type" => "application/json" },
            body: JSON.generate({ "error" => { "message" => "slow down" } }),
          }
        end
      end.new
    protocol = codex_protocol(adapter:)

    assert_raises(SimpleInference::HTTPError) do
      protocol.create(model: "gpt-5-codex", input: "Hello")
    end
  end

  # --- Declared-vocabulary + extra_body contract (the transplant template) ---

  def test_create_rejects_unknown_options_naming_them_and_extra_body
    protocol = codex_protocol(adapter: streaming_adapter(completed_sse))

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gpt-5-codex", input: "Hello", max_tokens: 128)
      end

    assert_includes error.message, "max_tokens"
    assert_includes error.message, "extra_body"
  end

  def test_stream_rejects_unknown_options_eagerly
    protocol = codex_protocol(adapter: streaming_adapter(completed_sse))

    assert_raises(SimpleInference::ValidationError) do
      protocol.stream(model: "gpt-5-codex", input: "Hello", instructionz: "typo")
    end
  end

  def test_extra_body_wire_fields_reach_the_wire_verbatim
    body = wire_body_for_create(extra_body: { "prompt_cache_key" => "cache-1" })

    assert_equal "cache-1", body.fetch("prompt_cache_key")
  end

  # extra_body is the caller's VERBATIM escape hatch: the declared-vocabulary
  # rejection of max_output_tokens never applies to wire fields the caller
  # spelled out explicitly.
  def test_extra_body_bypasses_the_declared_max_output_tokens_rejection
    body = wire_body_for_create(extra_body: { "max_output_tokens" => 64 })

    assert_equal 64, body.fetch("max_output_tokens")
  end

  def test_extra_body_collision_with_the_forced_store_default_raises
    protocol = codex_protocol(adapter: streaming_adapter(completed_sse))

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gpt-5-codex", input: "Hello", extra_body: { "store" => true })
      end

    assert_includes error.message, "store"
  end

  # --- Auth/route header surface as PROFILE facts ---
  # Frozen header contract (register codex section): Authorization Bearer and
  # ChatGPT-Account-ID are CREDENTIAL-derived and merge from Config at
  # execution; originator (codex_cli_rs) and the lite marker are the
  # non-credential protocol markers pinned here.

  def test_every_codex_request_carries_the_originator_marker_header
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    protocol.create(model: "gpt-5-codex", input: "Hello")

    assert_equal "codex_cli_rs", adapter.last_request.fetch(:headers).fetch("originator")
  end


  # --- Responses-Lite (constructor-driven; the model-regex trigger is dead) ---
  # The lite body construction mirrors codex-rs build_responses_request at the
  # audited pin; the trigger is the registry profile's use_responses_lite wire
  # flag forwarded as a construction option.

  def test_lite_flag_marks_requests_with_the_internal_header_for_any_model
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:, lite: true)

    protocol.create(model: "gpt-5-codex", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "true", headers.fetch("x-openai-internal-codex-responses-lite")
  end

  def test_without_the_flag_a_gpt_5_6_model_name_no_longer_triggers_lite
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    # A GPT-5.6 family name: the name alone never selects the lite wire;
    # only the profile's flag does.
    protocol.create(model: "gpt-5.6", input: "Hello")

    env = adapter.last_request
    refute_includes env.fetch(:headers), "x-openai-internal-codex-responses-lite"
    body = JSON.parse(env.fetch(:body))
    refute_includes body, "instructions", "classic shape stays classic: blank instructions are omitted, never filled"
    assert_equal "message", body.fetch("input").fetch(0).fetch("type")
  end

  def test_protocol_option_keys_declare_the_lite_wire_flag
    # Fix 2 promoted the lane constants to construction facts: the markers
    # (originator, the lite marker header) and the intake defaults (store
    # pin, encrypted-reasoning include) are registry-declared wire_options
    # beside the path and the lite flag.
    assert_equal %i[
      responses_path use_responses_lite
      originator responses_lite_header
      default_store encrypted_reasoning_include
    ], SimpleInference::Protocols::CodexResponses.protocol_option_keys
  end

  def test_registry_forwards_the_lite_wire_flag_into_the_protocol
    profile = profile_for("codex_responses", provider_id: "codex_subscription", model_pin: "gpt-6-sol")
    config = SimpleInference::Config.new(base_url: "https://chatgpt.com/backend-api/codex", api_key: "k")

    protocol = SimpleInference::ApiFormat.protocol_for(profile: profile, config: config)

    compiled = protocol.compile_create(model: profile.model_pin, input: "Hello")
    body = JSON.parse(compiled.payload)
    assert_equal "true", compiled.headers.fetch("x-openai-internal-codex-responses-lite")
    refute_includes body, "instructions"
    assert_equal "additional_tools", body.fetch("input").fetch(0).fetch("type")
  end

  def test_lite_moves_tools_and_instructions_into_developer_prefix_items
    chat_shaped_tool = {
      "type" => "function",
      "function" => {
        "name" => "get_weather",
        "description" => "Weather lookup",
        "parameters" => { "type" => "object", "properties" => {} },
      },
    }
    body = wire_body_for_create(
      lite: true,
      model: "gpt-6-sol",
      instructions: "Be brief.",
      tools: [chat_shaped_tool],
      reasoning_effort: "low",
    )

    refute_includes body, "instructions"
    refute_includes body, "tools"

    input = body.fetch("input")
    additional_tools = input.fetch(0)
    assert_equal "additional_tools", additional_tools.fetch("type")
    assert_equal "developer", additional_tools.fetch("role")
    # The item carries the Responses-normalized tool JSON that would have
    # gone top-level in classic mode, folded into the `functions`
    # namespace (upstream create_tools_json_for_responses_lite).
    namespace = additional_tools.fetch("tools").fetch(0)
    assert_equal "namespace", namespace.fetch("type")
    assert_equal "functions", namespace.fetch("name")
    assert_equal ["get_weather"], namespace.fetch("tools").map { |tool| tool.fetch("name") }
    assert_equal "function", namespace.fetch("tools").first.fetch("type")
    refute_includes namespace.fetch("tools").first, "function"

    developer_message = input.fetch(1)
    assert_equal(
      {
        "type" => "message",
        "role" => "developer",
        "content" => [{ "type" => "input_text", "text" => "Be brief." }],
      },
      developer_message,
    )

    assert_equal "user", input.fetch(2).fetch("role")
    assert_equal false, body.fetch("parallel_tool_calls")
    assert_equal "all_turns", body.dig("reasoning", "context")
    assert_equal "low", body.dig("reasoning", "effort")
    assert_equal ["reasoning.encrypted_content"], body.fetch("include")
  end

  # The lite reshape rebuilds every input item key for key (the image
  # detail strip), so an assistant message's `phase` rides as handed: the
  # wire's own label on a message it produced is never lost to the prefix
  # rebuild.
  def test_codex_lite_keeps_the_assistant_phase
    body = wire_body_for_create(
      lite: true,
      model: "gpt-6-sol",
      input: [
        { "role" => "user", "content" => [{ "type" => "input_text", "text" => "go" }] },
        { "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "Reading it." }],
          "phase" => "commentary" },
      ],
    )

    assistant = body.fetch("input").find { |item| item["role"] == "assistant" }
    assert_equal(
      { "role" => "assistant", "content" => [{ "type" => "output_text", "text" => "Reading it." }],
        "phase" => "commentary" },
      assistant,
    )
  end

  def test_lite_sends_empty_additional_tools_and_no_instructions_default
    body = wire_body_for_create(lite: true, model: "gpt-6-sol")

    # Upstream: additional_tools is unconditionally the first input item (an
    # empty array when no tools); the developer instructions message is
    # conditional on caller text, and no filler is synthesized on either
    # shape (blank instructions are omitted like codex's serde skip).
    refute_includes body, "instructions"
    refute_includes body, "tools"

    input = body.fetch("input")
    assert_equal(
      { "type" => "additional_tools", "role" => "developer", "tools" => [] },
      input.fetch(0),
    )
    assert_equal "user", input.fetch(1).fetch("role")
    assert_equal false, body.fetch("parallel_tool_calls")
    # WP8 wire truth (HTTP 400 "X-OpenAI-Internal-Codex-Responses-Lite
    # requires `reasoning.context` to be `all_turns`"): the Lite marker
    # UNCONDITIONALLY requires reasoning.context, so the object is
    # synthesized even when no reasoning was requested.
    assert_equal({ "context" => "all_turns" }, body.fetch("reasoning"))
  end

  def test_lite_rejects_a_caller_context_other_than_all_turns
    # WP8 wire truth: the Lite marker accepts ONLY all_turns — a different
    # caller context is a loud local rejection, never a provider 400
    # round-trip. An explicit all_turns passes through untouched.
    error = assert_raises(SimpleInference::ValidationError) do
      wire_body_for_create(lite: true, model: "gpt-6-sol", reasoning: { effort: "low", context: "current_turn" })
    end
    assert_includes error.message, "all_turns"

    body = wire_body_for_create(lite: true, model: "gpt-6-sol", reasoning: { effort: "low", context: "all_turns" })
    assert_equal "all_turns", body.dig("reasoning", "context")
    assert_equal "low", body.dig("reasoning", "effort")
  end

  def test_stream_applies_lite_reshaping_too
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:, lite: true)

    protocol.stream(model: "gpt-6-sol", input: "Hello", reasoning_effort: "medium").each { |_event| nil }

    env = adapter.last_request
    assert_equal "true", env.fetch(:headers).fetch("x-openai-internal-codex-responses-lite")

    body = JSON.parse(env.fetch(:body))
    refute_includes body, "instructions"
    assert_equal "additional_tools", body.fetch("input").fetch(0).fetch("type")
    assert_equal false, body.fetch("parallel_tool_calls")
    assert_equal "all_turns", body.dig("reasoning", "context")
  end

  # --- Media ingress: bytes only (MediaInput), carriers rejected ---
  # Transport policy (register Input-media profiles v1): provider requests
  # embed prepared bytes inline; caller data URIs, URLs, host paths, and
  # provider file handles are loud rejections at the lane's lowering. The old
  # data-URI acceptance pins are killed drift.

  def test_media_input_bytes_lower_to_the_inline_base64_wire_form
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    input = [
      {
        "type" => "message",
        "role" => "user",
        "content" => [
          { "type" => "input_text", "text" => "look" },
          { "type" => "input_image", "image_url" => media },
        ],
      },
    ]
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", input: input)

    message = body.fetch("input").find { |item| item["type"] == "message" && item["role"] == "user" }
    image_part = message.fetch("content").find { |part| part["type"] == "input_image" }
    expected = "data:image/png;base64,#{[PNG_BYTES].pack("m0")}"
    assert_equal expected, image_part.fetch("image_url")
  end

  def test_lite_strips_detail_from_lowered_media_parts
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    input = [
      {
        "type" => "message",
        "role" => "user",
        "content" => [
          { "type" => "input_image", "image_url" => media, "detail" => "high" },
        ],
      },
      {
        "type" => "function_call_output",
        "call_id" => "call_1",
        "output" => [
          { "type" => "input_image", "image_url" => media, "detail" => "low" },
        ],
      },
    ]
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", input: input)

    wire_input = body.fetch("input")
    message = wire_input.find { |item| item["type"] == "message" && item["role"] == "user" }
    image_part = message.fetch("content").find { |part| part["type"] == "input_image" }
    refute_includes image_part, "detail"
    assert image_part.fetch("image_url").start_with?("data:image/png;base64,")

    tool_output = wire_input.find { |item| item["type"] == "function_call_output" }
    output_image = tool_output.fetch("output").first
    refute_includes output_image, "detail"
  end

  def test_classic_mode_keeps_detail_on_lowered_media_parts
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    input = [
      {
        "type" => "message",
        "role" => "user",
        "content" => [{ "type" => "input_image", "image_url" => media, "detail" => "high" }],
      },
    ]
    body = wire_body_for_create(model: "gpt-5-codex", input: input)

    image_part = body.fetch("input").fetch(0).fetch("content").fetch(0)
    assert_equal "high", image_part.fetch("detail")
    assert image_part.fetch("image_url").start_with?("data:image/png;base64,")
  end

  def test_caller_data_uri_is_a_loud_rejection
    input = [
      {
        "type" => "message",
        "role" => "user",
        "content" => [{ "type" => "input_image", "image_url" => "data:image/png;base64,AAA" }],
      },
    ]
    protocol = codex_protocol(adapter: streaming_adapter(completed_sse), lite: true)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gpt-6-sol", input: input)
      end

    assert_includes error.message, "MediaInput"
  end

  def test_caller_remote_url_is_a_loud_rejection_in_classic_mode_too
    input = [
      {
        "type" => "message",
        "role" => "user",
        "content" => [{ "type" => "input_image", "image_url" => { "url" => "https://example.com/cat.png" } }],
      },
    ]
    protocol = codex_protocol(adapter: streaming_adapter(completed_sse))

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "gpt-5-codex", input: input)
    end
  end

  # --- F5: the codex backend's routing hint and the pinned User-Agent
  # (codex-rs core/src/client.rs build_routing_hint_header; login/src/auth/
  # default_client.rs get_codex_user_agent). Both are body- or lane-derived,
  # so they belong beside the originator marker. The credential pair and
  # any session/thread ids stay Config headers merged at execution. ---

  def test_every_codex_request_carries_the_model_routing_hint
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    protocol.create(model: "gpt-6-sol", input: "Hello")

    assert_equal "model=gpt-6-sol", adapter.last_request.fetch(:headers).fetch("x-codex-routing-hint")
  end

  def test_the_routing_hint_appends_the_sent_service_tier
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    protocol.create(model: "gpt-6-astra", input: "Hello", service_tier: "priority")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "model=gpt-6-astra;tier=priority", headers.fetch("x-codex-routing-hint")
    assert_equal "priority", JSON.parse(adapter.last_request.fetch(:body)).fetch("service_tier")
  end

  def test_the_routing_hint_rides_the_compiled_request_too
    profile = profile_for("codex_responses", provider_id: "codex_subscription", model_pin: "gpt-6-sol")
    config = SimpleInference::Config.new(base_url: "https://chatgpt.com/backend-api/codex", api_key: "k")
    protocol = SimpleInference::ApiFormat.protocol_for(profile: profile, config: config)

    compiled = protocol.compile_create(model: profile.model_pin, input: "Hello")

    assert_equal "model=gpt-6-sol", compiled.headers.fetch("x-codex-routing-hint")
    assert_equal "codex_cli_rs", compiled.headers.fetch("originator")
  end

  def test_every_codex_request_carries_the_pinned_codex_user_agent
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:)

    protocol.create(model: "gpt-5-codex", input: "Hello")

    user_agent = adapter.last_request.fetch(:headers).fetch("User-Agent")
    assert_equal SimpleInference::Protocols::CodexResponses::USER_AGENT, user_agent
    assert_match(%r{\Acodex_cli_rs/\d+\.\d+\.\d+ \(\S+ \S+; \S+\)\z}, user_agent)
  end

  def test_a_caller_supplied_user_agent_wins_over_the_pinned_default
    adapter = streaming_adapter(completed_sse)
    protocol = SimpleInference::Protocols::CodexResponses.new(
      base_url: "http://example.com", adapter:, headers: { "User-Agent" => "cybros/1.0" }
    )

    protocol.create(model: "gpt-5-codex", input: "Hello")

    assert_equal "cybros/1.0", adapter.last_request.fetch(:headers).fetch("User-Agent")
  end

  # --- F6: the Responses-Lite `functions` namespace (codex-rs
  # tools/src/tool_spec.rs create_tools_json_for_responses_lite, gated by
  # provider.capabilities().namespace_tools which defaults on). Every
  # function/custom spec folds, in order, into ONE namespace item placed
  # at the index of the first such entry; every other spec stays in
  # place; a caller-supplied `functions` namespace merges into it. No
  # uuid-v5 item ids: those serve an incremental/WebSocket resume path
  # this gem does not have. ---

  def test_lite_folds_function_tools_into_the_functions_namespace
    weather = { "type" => "function", "name" => "get_weather", "parameters" => { "type" => "object" } }
    web_search = { "type" => "web_search" }
    shell = { "type" => "custom", "name" => "shell", "format" => { "type" => "text" } }
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", tools: [weather, web_search, shell])

    tools = body.fetch("input").fetch(0).fetch("tools")
    assert_equal %w[namespace web_search], tools.map { |tool| tool.fetch("type") }
    namespace = tools.fetch(0)
    assert_equal "functions", namespace.fetch("name")
    assert_equal "", namespace.fetch("description")
    assert_equal [weather, shell], namespace.fetch("tools")
    assert_equal web_search, tools.fetch(1)
  end

  def test_lite_places_the_namespace_at_the_first_function_index
    web_search = { "type" => "web_search" }
    weather = { "type" => "function", "name" => "get_weather" }
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", tools: [web_search, weather])

    tools = body.fetch("input").fetch(0).fetch("tools")
    assert_equal %w[web_search namespace], tools.map { |tool| tool.fetch("type") }
    assert_equal [weather], tools.fetch(1).fetch("tools")
  end

  def test_lite_merges_a_caller_functions_namespace_and_its_description_wins
    weather = { "type" => "function", "name" => "get_weather" }
    lookup = { "type" => "function", "name" => "lookup" }
    caller_namespace = {
      "type" => "namespace", "name" => "functions", "description" => "House tools", "tools" => [lookup],
    }
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", tools: [weather, caller_namespace])

    tools = body.fetch("input").fetch(0).fetch("tools")
    assert_equal 1, tools.length
    namespace = tools.fetch(0)
    assert_equal "functions", namespace.fetch("name")
    assert_equal "House tools", namespace.fetch("description")
    assert_equal [weather, lookup], namespace.fetch("tools")
  end

  def test_lite_keeps_a_differently_named_namespace_in_place
    other = { "type" => "namespace", "name" => "house", "description" => "", "tools" => [] }
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", tools: [other])

    assert_equal [other], body.fetch("input").fetch(0).fetch("tools")
  end

  def test_lite_drops_an_empty_caller_functions_namespace_like_the_reference
    # tool_spec.rs inserts the namespace only when its tools are non-empty.
    empty = { "type" => "namespace", "name" => "functions", "description" => "", "tools" => [] }
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", tools: [empty])

    assert_equal [], body.fetch("input").fetch(0).fetch("tools")
  end

  def test_lite_folds_chat_shaped_function_tools_after_wire_normalization
    chat_shaped = {
      "type" => "function",
      "function" => { "name" => "get_weather", "description" => "Weather lookup", "parameters" => { "type" => "object" } },
    }
    body = wire_body_for_create(lite: true, model: "gpt-6-sol", tools: [chat_shaped])

    namespace = body.fetch("input").fetch(0).fetch("tools").fetch(0)
    assert_equal "namespace", namespace.fetch("type")
    assert_equal(
      [{ "type" => "function", "name" => "get_weather", "description" => "Weather lookup", "parameters" => { "type" => "object" } }],
      namespace.fetch("tools")
    )
  end

  def test_classic_shape_keeps_function_tools_top_level_and_unfolded
    weather = { "type" => "function", "name" => "get_weather" }
    body = wire_body_for_create(model: "gpt-6-sol", tools: [weather])

    assert_equal [weather], body.fetch("tools")
  end

  private

  def codex_protocol(adapter:, lite: false)
    options = { base_url: "http://example.com", adapter: }
    options[:use_responses_lite] = true if lite
    SimpleInference::Protocols::CodexResponses.new(**options)
  end

  def streaming_adapter(sse)
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      define_method(:call_stream) do |request, &block|
        @last_request = request
        block.call(sse)
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
  end

  def sse_events(*payloads)
    events = payloads.map { |payload| "data: #{JSON.generate(payload)}\n\n" }
    "#{events.join}data: [DONE]\n\n"
  end

  def completed_sse
    sse_events(
      {
        "type" => "response.completed",
        "response" => {
          "status" => "completed",
          "output" => [
            { "type" => "message", "content" => [{ "type" => "output_text", "text" => "ok" }] },
          ],
          "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
        },
      }
    )
  end

  def wire_body_for_create(model: "gpt-5-codex", input: "Hello", lite: false, **params)
    adapter = streaming_adapter(completed_sse)
    protocol = codex_protocol(adapter:, lite:)
    protocol.create(model:, input:, **params)
    JSON.parse(adapter.last_request.fetch(:body))
  end
end
