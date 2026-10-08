require "json"
require "test_helper"
require_relative "anthropic_protocol_helpers"

class TestAnthropicReasoning < Minitest::Test
  include AnthropicProtocolHelpers

  def test_create_maps_thinking_content_part_into_native_anthropic_block
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-4-6", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Continue." },
        {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "Replayed reasoning.", signature: "sig_abc" },
            { type: "input_text", text: "Prior answer." },
          ],
        },
        { role: "user", content: "Next." },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assistant = request_body.fetch("messages").fetch(1)
    assert_equal "assistant", assistant.fetch("role")
    thinking_block = assistant.fetch("content").fetch(0)
    assert_equal "thinking", thinking_block.fetch("type")
    assert_equal "Replayed reasoning.", thinking_block.fetch("thinking")
    assert_equal "sig_abc", thinking_block.fetch("signature")
    assert_equal "text", assistant.fetch("content").fetch(1).fetch("type")
  end

  def test_create_drops_thinking_content_part_without_signature
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-4-6", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Continue." },
        {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "Unsigned reasoning.", signature: "" },
            { type: "input_text", text: "Prior answer." },
          ],
        },
        { role: "user", content: "Next." },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    content_types = request_body.fetch("messages").fetch(1).fetch("content").map { |block| block.fetch("type") }
    refute_includes content_types, "thinking"
    assert_equal %w[text], content_types
  end

  def test_stream_yields_thinking_as_reasoning_deltas
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-opus-4-1","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2,"output_tokens":0}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need "}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"tool."}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_123"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Done"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":1}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}\n\n)
          sse << %(event: message_stop\n)
          sse << %(data: {"type":"message_stop"}\n\n)

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "claude-opus-4-1", max_output_tokens: 4096, input: "Hello").to_a
    reasoning_deltas = events.grep(SimpleInference::Responses::Events::ReasoningDelta).map(&:delta)
    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }
    reasoning_item = completed.result.output_items.find { |item| item["type"] == "reasoning" }

    assert_equal ["Need ", "tool."], reasoning_deltas
    assert_equal "Done", completed.result.output_text
    assert_equal "Need tool.", reasoning_item.fetch("text")
    assert_equal "sig_123", reasoning_item.fetch("signature")
  end

  # --- Reasoning lowering. Model-name dispatch is DEAD: the same request
  # options lower to the same wire bytes on every model id. Legality lives
  # with the caller/profile and the server, never in a claude-* regex. ---

  def test_reasoning_effort_lowers_identically_across_model_ids
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    # An Opus 5.x id (claude-opus-5-5) matches NONE of the excised model
    # regexes, so it would fall into the manual-budget branch the register
    # records as a 4.7+ server 400.
    bodies =
      %w[claude-opus-4-1 claude-sonnet-4-6 claude-opus-5-5 claude-mythos-preview].map do |model|
        protocol.create(model: model, input: "Hello", max_output_tokens: 4096, reasoning_effort: "medium")
        JSON.parse(adapter.last_request.fetch(:body)).tap { |body| body.delete("model") }
      end

    bodies.each do |body|
      assert_equal({ "type" => "adaptive", "display" => "summarized" }, body.fetch("thinking"))
      assert_equal({ "effort" => "medium" }, body.fetch("output_config"))
      assert_equal 4096, body.fetch("max_tokens"), "the caller's number on every model — the protocol invents none"
    end
    assert_equal 1, bodies.uniq.length, "model id must not select a lowering branch"
  end

  def test_reasoning_effort_result_still_surfaces_thinking_items
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              id: "msg_123",
              content: [
                { type: "thinking", thinking: "Need a short answer.", signature: "sig_123" },
                { type: "text", text: "ok" },
              ],
              stop_reason: "end_turn",
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    result = protocol.create(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello", reasoning_effort: "high")
    request_body = JSON.parse(adapter.last_request.fetch(:body))
    reasoning_item = result.output_items.find { |item| item["type"] == "reasoning" }

    assert_equal({ "type" => "adaptive", "display" => "summarized" }, request_body.fetch("thinking"))
    assert_equal({ "effort" => "high" }, request_body.fetch("output_config"))
    assert_equal "Need a short answer.", reasoning_item.fetch("text")
    assert_equal "sig_123", reasoning_item.fetch("signature")
    assert_equal "ok", result.output_text
  end

  def test_xhigh_reasoning_effort_is_lowered_natively_never_clamped
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    # claude-sonnet-4-6 used to be clamped xhigh->max by a model regex.
    protocol.create(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", reasoning_effort: "xhigh")
    request_body = JSON.parse(adapter.last_request.fetch(:body))

    assert_equal({ "type" => "adaptive", "display" => "summarized" }, request_body.fetch("thinking"))
    assert_equal({ "effort" => "xhigh" }, request_body.fetch("output_config"))
  end

  # "none" is an explicit disable request; omitting the param would silently
  # run adaptive thinking on default-adaptive models. The explicit wire
  # disable is the faithful lowering for EVERY model id.
  def test_none_reasoning_effort_lowers_to_explicit_disabled_thinking_for_every_model
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    %w[claude-fable-5 claude-sonnet-5 claude-opus-4-1].each do |model|
      protocol.create(model: model, input: "Hello", max_output_tokens: 4096, reasoning_effort: "none")
      request_body = JSON.parse(adapter.last_request.fetch(:body))

      assert_equal({ "type" => "disabled" }, request_body.fetch("thinking"), model)
      refute request_body.key?("output_config"), model
    end
  end

  # Deterministic construction: out-of-vocabulary efforts are locally rejected
  # with zero outbound IO (the old code clamped unknown->medium, minimal->low).
  def test_out_of_vocabulary_reasoning_effort_raises_without_io
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    %w[minimal bogus].each do |effort|
      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello", reasoning_effort: effort)
        end

      assert_includes error.message, effort.inspect
      assert_includes error.message, "never clamps"
    end
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_explicit_manual_thinking_lowers_verbatim_without_max_tokens_bump
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-1",
      input: "Hello",
      max_output_tokens: 4096,
      thinking: { type: "enabled", budget_tokens: 2048 }
    )
    request_body = JSON.parse(adapter.last_request.fetch(:body))

    assert_equal({ "type" => "enabled", "budget_tokens" => 2048 }, request_body.fetch("thinking"))
    assert_equal 4096, request_body.fetch("max_tokens")
  end

  # Deterministic construction: the old code silently RAISED max_tokens to
  # budget+1024; the faithful protocol rejects the contradiction instead.
  def test_manual_thinking_budget_at_or_above_max_tokens_raises_instead_of_silent_bump
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-1",
          input: "Hello",
          max_output_tokens: 2048,
          thinking: { type: "enabled", budget_tokens: 2048 }
        )
      end

    assert_includes error.message, "max_tokens"
    assert_includes error.message, "budget_tokens"
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  # Deterministic construction: register minimum for manual budgets is 1,024.
  def test_manual_thinking_budget_below_minimum_raises
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-1",
          input: "Hello",
          max_output_tokens: 4096,
          thinking: { type: "enabled", budget_tokens: 512 }
        )
      end

    assert_includes error.message, "1024"
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  # Deterministic construction: effort rides output_config.effort in adaptive
  # mode only; pairing it with a manual/disabled thinking hash is a
  # contradiction the protocol surfaces instead of silently dropping effort.
  def test_reasoning_effort_conflicts_with_non_adaptive_explicit_thinking
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-1",
          input: "Hello",
          max_output_tokens: 4096,
          reasoning_effort: "high",
          thinking: { type: "enabled", budget_tokens: 2048 }
        )
      end

    assert_includes error.message, "adaptive"
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_reasoning_effort_composes_with_explicit_adaptive_thinking
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: "Hello",
      reasoning_effort: "high",
      thinking: { type: "adaptive", display: "summarized" }
    )
    request_body = JSON.parse(adapter.last_request.fetch(:body))

    # The caller's explicit display choice reaches the wire verbatim; the
    # protocol itself never injects one (the default is a register fixture
    # pin, not an implementation guess).
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, request_body.fetch("thinking"))
    assert_equal({ "effort" => "high" }, request_body.fetch("output_config"))
  end

  def test_redacted_thinking_blocks_round_trip
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              id: "msg_123",
              content: [
                { type: "redacted_thinking", data: "opaque-blob" },
                { type: "text", text: "ok" },
              ],
              stop_reason: "end_turn"
            ),
          }
        end
      end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    result = protocol.create(model: "claude-fable-5", max_output_tokens: 4096, input: "Hello")
    item = result.output_items.find { |candidate| candidate["type"] == "redacted_thinking" }

    refute_nil item
    assert_equal "opaque-blob", item.fetch("data")
    assert_equal({ "type" => "redacted_thinking", "data" => "opaque-blob" }, item.fetch("provider_payload"))
    assert_equal "ok", result.output_text

    # Replay direction: the block must reach the wire verbatim, not raise.
    protocol.create(
      model: "claude-fable-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Continue." },
        {
          role: "assistant",
          content: [
            { type: "redacted_thinking", data: "opaque-blob" },
            { type: "input_text", text: "Prior answer." },
          ],
        },
        { role: "user", content: "Next." },
      ]
    )

    assistant = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").fetch(1)
    assert_equal "assistant", assistant.fetch("role")
    assert_equal({ "type" => "redacted_thinking", "data" => "opaque-blob" }, assistant.fetch("content").fetch(0))
    assert_equal "text", assistant.fetch("content").fetch(1).fetch("type")
  end

  # F10b: the `thinking_binding` construction fact (the fable-5-1 row's
  # wire option, scoped by model id) lowers to
  # thinking.block_binding.prefix_mismatch_behavior on adaptive AND manual
  # enabled thinking, never on disabled, and the field brings its beta.
  def test_thinking_binding_lowers_to_block_binding_on_adaptive_and_enabled_never_disabled
    build = lambda do
      adapter = capturing_adapter
      protocol = SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, thinking_binding: "drop_block"
      )
      [adapter, protocol]
    end

    adapter, protocol = build.call
    protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096, reasoning_effort: "high")
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal(
      { "type" => "adaptive", "display" => "summarized", "block_binding" => { "prefix_mismatch_behavior" => "drop_block" } },
      body.fetch("thinking")
    )
    assert_equal "thinking-binding-controls-2026-08-01", adapter.last_request.fetch(:headers).fetch("anthropic-beta")

    adapter, protocol = build.call
    protocol.create(
      model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096,
      thinking: { type: "enabled", budget_tokens: 2048 }
    )
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "prefix_mismatch_behavior" => "drop_block" }, body.fetch("thinking").fetch("block_binding"))
    assert_equal 2048, body.fetch("thinking").fetch("budget_tokens")
    assert_equal "thinking-binding-controls-2026-08-01", adapter.last_request.fetch(:headers).fetch("anthropic-beta")

    adapter, protocol = build.call
    protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096, reasoning_effort: "none")
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "type" => "disabled" }, body.fetch("thinking"), "disabled thinking binds nothing")
    refute adapter.last_request.fetch(:headers).key?("anthropic-beta"), "no field, no beta"

    adapter, protocol = build.call
    protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096)
    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("thinking"), "no thinking requested, nothing to bind"
    refute adapter.last_request.fetch(:headers).key?("anthropic-beta")

    adapter, protocol = build.call
    protocol.create(
      model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096,
      thinking: { type: "adaptive", block_binding: { prefix_mismatch_behavior: "error" } }
    )
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "prefix_mismatch_behavior" => "error" }, body.fetch("thinking").fetch("block_binding"),
      "a caller's explicit block_binding wins over the construction fact")

    unbound = capturing_adapter
    SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: unbound)
      .create(model: "claude-fable-5", input: "Hello", max_output_tokens: 4096, reasoning_effort: "high")
    body = JSON.parse(unbound.last_request.fetch(:body))
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, body.fetch("thinking"),
      "a row without the fact sends today's bytes")

    error = assert_raises(SimpleInference::ConfigurationError) do
      SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", thinking_binding: "strip")
    end
    assert_includes error.message, "thinking_binding"
  end
end
