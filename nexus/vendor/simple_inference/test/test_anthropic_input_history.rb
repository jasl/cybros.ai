require "json"
require "test_helper"
require_relative "anthropic_protocol_helpers"

class TestAnthropicInputHistory < Minitest::Test
  include AnthropicProtocolHelpers

  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze

  # The Responses family's `developer` role has no twin on this wire: it
  # lowers to `user` and stays WHERE THE CALLER PLACED IT in the list —
  # hoisting it into the system field would move it ahead of everything
  # behind it (Nexus S-F r2 (5)). An unknown role is still the loud refusal.
  def test_create_lowers_developer_to_user_and_still_refuses_unknown_roles
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "system", content: "slots" }, { role: "user", content: "memory" },
        { role: "developer", content: "env" }, { role: "user", content: "Hi" },
      ]
    )
    body = JSON.parse(adapter.last_request.fetch(:body))
    message = body.fetch("messages").fetch(0)
    assert_equal 1, body.fetch("messages").length, "adjacent user turns merge, as this wire always did"
    assert_equal "user", message.fetch("role")
    assert_equal ["memory", "env", "Hi"], message.fetch("content").map { |block| block.fetch("text") },
      "the developer text stays between memory and the prompt — lowered in place"
    assert_equal "slots", body.fetch("system"), "system alone is lifted"
    # The kernel's admission reads ACCEPTED_ROLES, so the constant must name
    # what normalize_role admits: without `developer` here every rho
    # conversation on the direct Anthropic lane was parked
    # unsupported_input_role at turn 1 (the paid live_cache_tier lane,
    # 2026-09-18) before the wire that would have carried it.
    assert_includes SimpleInference::Protocols::AnthropicMessages::ACCEPTED_ROLES, "developer"

    refusing = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret", adapter: refusing
    )
    error = assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "claude-opus-5-5", max_output_tokens: 4096, input: [{ role: "banana", content: "x" }])
    end
    assert_includes error.message, "banana"
    assert_nil refusing.last_request, "an unknown role must never silently reach the wire"
  end

  def test_create_lowers_structured_instructions_into_a_cache_controlled_system_array
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [{ role: "user", content: "Hello" }],
      instructions: [
        { type: "text", text: "You are a coding agent.", cache_control: { type: "ephemeral" } },
      ]
    )

    system = JSON.parse(adapter.last_request.fetch(:body)).fetch("system")
    assert_instance_of Array, system
    assert_equal "text", system.fetch(0).fetch("type")
    assert_equal "You are a coding agent.", system.fetch(0).fetch("text")
    assert_equal({ "type" => "ephemeral" }, system.fetch(0).fetch("cache_control"))
  end

  def test_create_preserves_cache_control_on_structured_system_message_content
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        {
          role: "system",
          content: [
            { type: "text", text: "System preamble.", cache_control: { type: "ephemeral" } },
          ],
        },
        { role: "user", content: "Hello" },
      ]
    )

    system = JSON.parse(adapter.last_request.fetch(:body)).fetch("system")
    assert_instance_of Array, system
    assert_equal "System preamble.", system.fetch(0).fetch("text")
    assert_equal({ "type" => "ephemeral" }, system.fetch(0).fetch("cache_control"))
  end

  def test_create_keeps_string_system_when_instructions_carry_no_cache_control
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [{ role: "user", content: "Hello" }],
      instructions: "Be terse."
    )

    assert_equal "Be terse.", JSON.parse(adapter.last_request.fetch(:body)).fetch("system")
  end

  def test_create_preserves_cache_control_on_a_message_text_block
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        {
          role: "user",
          content: [
            { type: "text", text: "cached turn", cache_control: { type: "ephemeral" } },
          ],
        },
      ]
    )

    block = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").fetch(0).fetch("content").fetch(0)
    assert_equal "text", block.fetch("type")
    assert_equal "cached turn", block.fetch("text")
    assert_equal({ "type" => "ephemeral" }, block.fetch("cache_control"))
  end

  def test_create_preserves_cache_control_on_a_tool_result_tail_block
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        { role: "user", content: "run it" },
        { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
        { type: "function_call_output", call_id: "toolu_1", output: "done", cache_control: { type: "ephemeral" } },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    tool_result = messages.last.fetch("content").fetch(0)
    assert_equal "tool_result", tool_result.fetch("type")
    assert_equal "done", tool_result.fetch("content")
    assert_equal({ "type" => "ephemeral" }, tool_result.fetch("cache_control"))
  end

  # --- Media ingress: bytes only (MediaInput), carriers rejected ---
  # Transport policy (register Input-media profiles v1): provider requests
  # embed prepared bytes inline as base64; caller data URIs, URLs, host
  # paths, and provider file handles are loud rejections at the lane's
  # lowering — even though the Anthropic wire accepts a url source.

  def test_media_input_bytes_lower_to_the_base64_source_block
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        {
          role: "user",
          content: [
            { type: "text", text: "look" },
            { type: "input_image", image_url: media },
          ],
        },
      ]
    )

    block = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").fetch(0).fetch("content").fetch(1)
    assert_equal "image", block.fetch("type")
    assert_equal(
      { "type" => "base64", "media_type" => "image/png", "data" => [PNG_BYTES].pack("m0") },
      block.fetch("source")
    )
  end

  def test_caller_data_uri_image_is_a_loud_rejection_with_zero_io
    protocol = exploding_protocol

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-8", max_output_tokens: 4096,
          input: [{ role: "user", content: [{ type: "input_image", image_url: "data:image/png;base64,AAAA" }] }]
        )
      end

    assert_includes error.message, "MediaInput"
  end

  def test_caller_remote_url_image_is_a_loud_rejection_with_zero_io
    protocol = exploding_protocol

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "claude-opus-4-8", max_output_tokens: 4096,
        input: [{ role: "user", content: [{ type: "image", image_url: { url: "https://example.com/cat.png" } }] }]
      )
    end
  end

  def test_caller_native_url_source_block_is_a_loud_rejection_with_zero_io
    protocol = exploding_protocol

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "claude-opus-4-8", max_output_tokens: 4096,
        input: [{ role: "user", content: [{ type: "image", source: { type: "url", url: "https://example.com/cat.png" } }] }]
      )
    end
  end

  # --- Role/final-turn disposition (the vendor's Opus 5.5 migration guide:
  # claude-opus-5-5 rejects a last nonempty assistant prefill; prior
  # assistant history remains eligible).
  # Deterministic constructions: zero outbound IO on rejection. ---

  def test_assistant_last_input_is_rejected_preflight
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-5-5", max_output_tokens: 4096,
          input: [
            { role: "user", content: "Hello" },
            { role: "assistant", content: "A prefill." },
          ]
        )
      end

    assert_equal(
      "anthropic_messages rejects assistant-last input: the final nonempty turn must not be an " \
      "assistant prefill (prior assistant turns remain eligible)",
      error.message
    )
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_unanswered_function_call_tail_is_rejected_as_assistant_last
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-5-5", max_output_tokens: 4096,
          input: [
            { role: "user", content: "run it" },
            { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
          ]
        )
      end

    assert_includes error.message, "assistant-last"
    assert_nil adapter.last_request
  end

  def test_prior_assistant_history_with_user_last_turn_is_accepted
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Prior answer." },
        { role: "user", content: "Next." },
      ]
    )

    roles = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").map { |message| message.fetch("role") }
    assert_equal %w[user assistant user], roles
  end

  # The continuation replays the refused call beside its error result; the
  # wire needs an object there, so the partial lowers to `{}` on the way
  # BACK — the refusal itself rides in the paired tool_result.
  def test_create_replays_a_truncated_call_as_an_empty_tool_use_input
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Compute." },
        { "type" => "function_call", "call_id" => "toolu_123", "name" => "calculator", "arguments" => %({"expression":"2 + ) },
        { "type" => "function_call_output", "call_id" => "toolu_123", "output" => "<tool_use_error>invalid_tool_arguments</tool_use_error>" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    tool_use = messages.fetch(1).fetch("content").fetch(0)
    assert_equal({ "type" => "tool_use", "id" => "toolu_123", "name" => "calculator", "input" => {} }, tool_use)
    assert_equal "toolu_123", messages.fetch(2).fetch("content").fetch(0).fetch("tool_use_id")
  end

  # F7: the wire has an `is_error` field on tool_result; the neutral payload's
  # flag lowers to it (absent when false), on both input spellings.
  def test_tool_result_is_error_lowers_to_the_wire_field
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "run both" },
        { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
        { type: "function_call", call_id: "toolu_2", name: "bash", arguments: "{}" },
        { type: "function_call_output", call_id: "toolu_1", output: "<tool_use_error>boom</tool_use_error>", is_error: true },
        { role: "tool", tool_call_id: "toolu_2", content: "fine" },
      ]
    )

    results = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").last.fetch("content")
    assert_equal true, results.fetch(0).fetch("is_error")
    assert_equal "<tool_use_error>boom</tool_use_error>", results.fetch(0).fetch("content"), "the text marker stays beside the field"
    refute results.fetch(1).key?("is_error"), "false is absence, never a false byte"

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "run" },
        { type: "function_call", call_id: "toolu_3", name: "bash", arguments: "{}" },
        { role: "tool", tool_call_id: "toolu_3", content: "boom", is_error: true },
      ]
    )
    tool_result = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").last.fetch("content").fetch(0)
    assert_equal true, tool_result.fetch("is_error")
  end

  # A FOREIGN call id reaches this wire after a model switch: kimi's
  # `read:0` is a 400 (`tool_use.id` must match ^[a-zA-Z0-9_-]+$). The
  # lowering scrubs it the way opencode does
  # (anthropic-messages.ts scrubToolCallID) — deterministically, so the
  # tool_use and its tool_result still pair — on both input spellings.
  def test_foreign_call_ids_are_scrubbed_to_the_wire_pattern_and_still_pair
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "read both" },
        { type: "function_call", call_id: "read:0", name: "read", arguments: "{}" },
        { type: "function_call_output", call_id: "read:0", output: "alpha" },
        { role: "assistant", content: "", tool_calls: [{ id: "functions.ls:1", type: "function", function: { name: "ls", arguments: "{}" } }] },
        { role: "tool", tool_call_id: "functions.ls:1", content: "a.txt" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    uses = messages.flat_map { |m| m.fetch("content") }.select { |b| b["type"] == "tool_use" }
    results = messages.flat_map { |m| m.fetch("content") }.select { |b| b["type"] == "tool_result" }
    assert_equal %w[read_0 functions_ls_1], uses.map { |b| b.fetch("id") }
    assert_equal %w[read_0 functions_ls_1], results.map { |b| b.fetch("tool_use_id") }
  end

  # F11 (without the fact): a NON-LEADING system entry lowers IN PLACE to
  # user text — the developer-role rule in the vendor's own spelling —
  # never hoisted ahead of the history it follows; the leading run is
  # still the top-level `system`.
  def test_non_leading_system_lowers_in_place_to_user_text_without_the_row_fact
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-5", max_output_tokens: 4096,
      input: [
        { role: "system", content: "slots" }, { role: "system", content: "memory" },
        { role: "user", content: "first" },
        { role: "assistant", content: "reply" },
        { role: "system", content: [{ type: "text", text: "operator note", cache_control: { type: "ephemeral" } }] },
        { role: "user", content: "second" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "slots\n\nmemory", body.fetch("system"), "the leading run alone is hoisted"
    messages = body.fetch("messages")
    assert_equal %w[user assistant user], messages.map { |message| message.fetch("role") }
    assert_equal ["operator note", "second"], messages.fetch(2).fetch("content").map { |block| block.fetch("text") }
    assert_equal({ "type" => "ephemeral" }, messages.fetch(2).fetch("content").fetch(0).fetch("cache_control"))
  end

  # F11 (with the fact): the entry stays a wire `role: system` message where
  # the caller placed it, cache_control kept; the leading run is still hoisted.
  def test_non_leading_system_stays_in_place_as_a_system_message_under_the_row_fact
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, mid_conversation_system: true
    )

    protocol.create(
      model: "claude-fable-5-1", max_output_tokens: 4096,
      input: [
        { role: "system", content: "slots" },
        { role: "user", content: "first" },
        { role: "assistant", content: "reply" },
        { role: "user", content: "second" },
        { role: "system", content: [{ type: "text", text: "operator note", cache_control: { type: "ephemeral" } }] },
        { role: "assistant", content: "ack" },
        { role: "user", content: "third" },
        { role: "system", content: "trailing directive" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "slots", body.fetch("system")
    messages = body.fetch("messages")
    assert_equal %w[user assistant user system assistant user system], messages.map { |message| message.fetch("role") }
    assert_equal(
      [{ "type" => "text", "text" => "operator note", "cache_control" => { "type" => "ephemeral" } }],
      messages.fetch(3).fetch("content")
    )
    assert_equal [{ "type" => "text", "text" => "trailing directive" }], messages.fetch(6).fetch("content")
    refute adapter.last_request.fetch(:headers).key?("anthropic-beta"), "GA on the row's models — no beta"
  end

  # F11's placement guard (opencode's canUseNativeSystemUpdate as a local
  # refusal, since the vendor 400s the same shapes): a system entry must
  # follow a user turn (or tool results), never an assistant turn or another
  # system entry, and what follows it must be the assistant's turn.
  def test_mid_conversation_system_placement_is_guarded_locally_under_the_row_fact
    refusal = lambda do |input|
      adapter = capturing_adapter
      protocol = SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, mid_conversation_system: true
      )
      error = assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "claude-fable-5-1", max_output_tokens: 4096, input: input)
      end
      assert_nil adapter.last_request, "a refused placement produces zero outbound IO"
      error.message
    end

    after_assistant = refusal.call([
      { role: "user", content: "first" }, { role: "assistant", content: "reply" },
      { role: "system", content: "note" }, { role: "user", content: "second" },
    ])
    assert_includes after_assistant, "must follow a user turn"

    adjacent = refusal.call([
      { role: "user", content: "first" },
      { role: "system", content: "one" }, { role: "system", content: "two" },
    ])
    assert_includes adjacent, "must follow a user turn"

    before_user = refusal.call([
      { role: "user", content: "first" }, { role: "system", content: "note" }, { role: "user", content: "second" },
    ])
    assert_includes before_user, "must be the assistant's"

    splits_tool_results = refusal.call([
      { role: "user", content: "run" },
      { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
      { role: "system", content: "note" },
      { type: "function_call_output", call_id: "toolu_1", output: "done" },
    ])
    assert_includes splits_tool_results, "must follow a user turn"
  end

  # F13's gem half: an `output_config`-only system entry (content []) passes
  # through in place as a wire message under the fact, bringing the
  # mid-conversation-output-config beta; a row without the fact has no
  # lowering for it and refuses.
  def test_output_config_only_system_entry_passes_through_in_place_under_the_row_fact
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, mid_conversation_system: true
    )

    protocol.create(
      model: "claude-fable-5-1", max_output_tokens: 4096, reasoning_effort: "high",
      input: [
        { role: "user", content: "first" }, { role: "assistant", content: "reply" },
        { role: "user", content: "second" },
        { role: "system", content: [], output_config: { effort: "low" } },
        { role: "assistant", content: "ack" }, { role: "user", content: "third" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "role" => "system", "content" => [], "output_config" => { "effort" => "low" } }, body.fetch("messages").fetch(3))
    assert_equal({ "effort" => "high" }, body.fetch("output_config"), "the top-level effort is the caller's, untouched")
    assert_equal "mid-conversation-output-config-2026-07-01", adapter.last_request.fetch(:headers).fetch("anthropic-beta")

    plain = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: plain)
    error = assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "claude-sonnet-5", max_output_tokens: 4096,
        input: [
          { role: "user", content: "first" },
          { role: "system", content: [], output_config: { effort: "low" } },
        ]
      )
    end
    assert_includes error.message, "output_config"
    assert_nil plain.last_request
  end
end
