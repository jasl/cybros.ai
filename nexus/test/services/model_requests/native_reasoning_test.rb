require "test_helper"

class ModelRequests::NativeReasoningTest < ActiveSupport::TestCase
  Invocation = Data.define(:reasoning_enabled)
  ChatResult = Data.define(:output_items, :assistant_message, :usage)
  CountSelection = Data.define(:execution_profile, :reasoning)
  Reasoning = Data.define(:enabled)

  test "normalization and storage retain each native reasoning value's origin" do
    origin = { "provider_id" => "openai_api", "model_id" => "gpt-6.2-sol", "api_format" => "openai_responses" }
    item = Nexus::ReasoningInputItem.new(type: "reasoning_item", native_origin: origin,
      payload: { "type" => "reasoning", "encrypted_content" => "opaque", "summary" => [] })
    part = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      native_origin: { "provider_id" => "anthropic", "model_id" => "claude-opus-5-5", "api_format" => "anthropic_messages" },
      payload: { "type" => "thinking", "thinking" => "plan", "signature" => "signed" })
    input = [item, Nexus::TextInputMessage.new(role: "assistant", parts: [part])]

    normalized = ModelSelection::Workloads.normalize_input(workload: "text_generation", input: input)
    assert_nil normalized.refusal
    stored = JSON.parse(JSON.generate(Nexus::InputEntries.for(normalized.value)))
    assert_equal input, Nexus::InputEntries.from(entries: stored, workload: "text_generation")
  end

  test "raw reasoning without origin remains caller-authored rather than being downgraded" do
    item = Nexus::ReasoningInputItem.new(type: "reasoning_item",
      payload: { "type" => "reasoning", "encrypted_content" => "raw-opaque", "summary" => [] })
    part = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      payload: { "type" => "thinking", "thinking" => "raw plan", "signature" => "raw-signature" })
    input = [item, Nexus::TextInputMessage.new(role: "assistant", parts: [part])]

    assert_equal [item.payload, { "role" => "assistant", "content" => [part.payload] }],
      lower(input, model: "openai_api/gpt-6.1-terra", enabled: false)
    assert_not item.to_h.key?("native_origin")
    assert_not part.to_h.key?("native_origin")
  end

  test "unsigned Gemini summaries stay native on Gemini and cross providers as assistant text" do
    origin = { "provider_id" => "gemini", "model_id" => "another-gemini-model", "api_format" => "gemini_generate_content" }
    thought = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      native_origin: origin, payload: { "type" => "thought", "text" => "portable thought" })
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [thought])]

    assert_equal [thought.payload], lower(input, model: "gemini/gemini-4-hydrogen").sole.fetch("content")
    assert_equal [{ "type" => "input_text", "text" => "Prior model's reasoning summary:\nportable thought" }],
      lower(input, model: "openai_api/gpt-6.2-sol").sole.fetch("content")
  end

  # A sealed prefix follows the ladder's own rule: Anthropic's blocks pass
  # to another Anthropic model unchanged (its API drops what the model
  # cannot read). Responses permits compatible same-family upgrades.
  test "a sealed prefix passes Anthropic blocks across its models and only the summary of a foreign Responses item" do
    opus = { "provider_id" => "anthropic", "model_id" => "claude-opus-5-5", "api_format" => "anthropic_messages" }
    block = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, native_origin: opus,
      payload: { "type" => "thinking", "thinking" => "plan", "signature" => "signed" })
    answer = Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: "answer")
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [block, answer])]

    assert_equal [block.payload, { "type" => "input_text", "text" => "answer" }],
      lower(input, model: "anthropic/claude-haiku-5-5").sole.fetch("content")

    sol = { "provider_id" => "openai_api", "model_id" => "gpt-6.2-sol", "api_format" => "openai_responses" }
    item = Nexus::ReasoningInputItem.new(type: "reasoning_item", native_origin: sol,
      payload: { "type" => "reasoning", "encrypted_content" => "opaque", "summary" => [{ "type" => "summary_text", "text" => "s" }] })
    assert_equal [item.payload], lower([item], model: "openai_api/gpt-6.2-sol")
    assert_equal [item.payload], lower([item], model: "openai_api/gpt-6.2-astra")
    assert_equal [{ "type" => "input_text", "text" => "Prior model's reasoning summary:\ns" }],
      lower([item], model: "openai_api/gpt-6.1-terra").sole.fetch("content")
  end

  test "a sealed custom Messages reply with a Claude model ID keeps only the visible answer across providers" do
    origin = { "provider_id" => "local", "model_id" => "claude-sonnet-5-5", "api_format" => "anthropic_messages" }
    thought = Nexus::ReasoningInputPart.new(type: "reasoning", native_origin: origin,
      payload: { "type" => "thinking", "thinking" => "local raw reasoning", "signature" => "local-signature" })
    answer = Nexus::TextInputPart.new(type: "text", text: "visible answer")
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [thought, answer])]

    assert_equal [{ "type" => "input_text", "text" => "visible answer" }],
      lower(input, model: "openai_api/gpt-6.2-sol").sole.fetch("content")
  end

  test "a Claude downgrade carries the summary at the new input and switching back preserves that signed prefix" do
    fable = { "provider_id" => "anthropic", "model_id" => "claude-fable-5-2", "api_format" => "anthropic_messages" }
    sonnet = fable.merge("model_id" => "claude-sonnet-5-5")
    source = Nexus::ReasoningInputPart.new(type: "reasoning", native_origin: fable,
      payload: { "type" => "thinking", "thinking" => "keep the selected route", "signature" => "fable-signature" })
    reply = Nexus::TextInputMessage.new(role: "assistant", parts: [source])
    ask = Nexus::TextInputMessage.new(role: "user", parts: [Nexus::TextInputPart.new(type: "text", text: "Continue")])
    prefix = [ask, reply, ask]
    unchanged = lower(prefix, model: "anthropic/claude-fable-5-2")
    switched = lower(prefix, model: "anthropic/claude-sonnet-5-5")
    assert_equal unchanged, switched.take(unchanged.size)
    assert_equal "Prior model's reasoning summary:\nkeep the selected route", switched.last.fetch("content").sole.fetch("text")

    disabled = lower(prefix, model: "anthropic/claude-haiku-5-5", enabled: false)
    assert_equal 1, disabled.to_json.scan(/Prior model's reasoning summary/).size
    assert_equal "assistant", disabled[1].fetch("role")
    assert_not_includes disabled.to_json, "fable-signature"
    summary = "Prior model's reasoning summary:\nkeep the selected route"
    assert_counted_text(prefix, "anthropic/claude-haiku-5-5", ["Continue", summary, "Continue"], enabled: false)
    assert_counted_text(prefix, "gemini/gemini-4-hydrogen", ["Continue", summary, "Continue"])
    assert_counted_text(prefix, "anthropic/claude-sonnet-5-5", ["Continue", "keep the selected route", "Continue", summary])

    # A text-only lower-model answer still fixes the switch boundary.
    visible = Nexus::TextInputMessage.new(role: "assistant", parts: ask.parts, native_origin: sonnet)
    continued = prefix + [visible, ask]
    assert_equal switched, lower(continued, model: "anthropic/claude-sonnet-5-5").take(switched.size)
    restored = lower(continued, model: "anthropic/claude-fable-5-2")
    assert_equal switched, restored.take(switched.size)
    assert_equal 1, restored.to_json.scan(/Prior model's reasoning summary/).size
    assert_equal source.payload, restored[1].fetch("content").sole
  end

  # The chat wire carries a message's reasoning as a field of the message,
  # never a content part: the broker's detail blocks verbatim, else the
  # plain reasoning text. A round that only called tools has no words, so
  # its message is the field alone and its calls fold onto it.
  test "chat reasoning lifts onto the assistant message as its own field" do
    kimi = { "provider_id" => "openrouter", "model_id" => "moonshotai/kimi-k3.1-pro", "api_format" => "openrouter_chat" }
    blocks = [{ "type" => "reasoning.text", "text" => "plan" }]
    details = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, native_origin: kimi,
      payload: { "type" => "reasoning_details", "blocks" => blocks })
    answer = Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: "answer")
    content = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, native_origin: kimi,
      payload: { "type" => "reasoning_content", "text" => "calls first" })

    assert_equal [{ "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "answer" }],
                    "reasoning_details" => blocks }],
      lower([Nexus::TextInputMessage.new(role: "assistant", parts: [details, answer])], model: "openrouter/moonshotai/kimi-k3.1-pro")
    assert_equal [{ "role" => "assistant", "reasoning_content" => "calls first" }],
      lower([Nexus::TextInputMessage.new(role: "assistant", parts: [content])], model: "openrouter/moonshotai/kimi-k3.1-pro")
    assert_equal [{ "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "answer" }] }],
      lower([Nexus::TextInputMessage.new(role: "assistant", parts: [details, answer])], model: "openrouter/z-ai/glm-5.3"),
      "another model reads nothing of it"
  end

  test "DeepSeek's plain-text reasoning item passes through on its own model" do
    origin = { "provider_id" => "deepseek", "model_id" => "deepseek-flash", "api_format" => "deepseek_responses" }
    item = Nexus::ReasoningInputItem.new(type: "reasoning_item", native_origin: origin,
      payload: { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "plan" }] })

    assert_equal [item.payload], lower([item], model: "deepseek/deepseek-flash")
    assert_empty lower([item], model: "deepseek/deepseek-v4-pro")
  end

  test "a foreign estimate skips unportable raw reasoning carried for a possible return to the origin" do
    input = [Nexus::ReasoningInputItem.new(type: "reasoning_item",
      native_origin: { "provider_id" => "deepseek", "model_id" => "deepseek-flash", "api_format" => "deepseek_responses" },
      payload: { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "private reasoning" }] }),
      Nexus::TextInputMessage.new(role: "assistant", parts: [Nexus::TextInputPart.new(type: "text", text: "the answer")])]
    assert_counted_text(input, "anthropic/claude-opus-5-5", ["the answer"])
    assert_equal ["the answer"], lower(input, model: "anthropic/claude-opus-5-5").sole.fetch("content").pluck("text")
  end

  test "generic chat reasoning survives capture, replay and request lowering" do
    origin = { "provider_id" => "kimi_code", "model_id" => "k3.1-pro", "api_format" => "openai_compatible_chat" }
    result = ChatResult.new(output_items: [], usage: {},
      assistant_message: { "reasoning_content" => "inspect the file first" })
    envelope = ModelReasoning::TraceBuilder.call(result: result,
      origin: { provider_id: origin.fetch("provider_id"), model_id: origin.fetch("model_id"),
        api_format: origin.fetch("api_format"), invocation_id: "test-invocation" },
      normalized_tool_calls: [])
    target = ModelReasoning::ReplayLadder::Target.new(provider_id: "kimi_code", model_id: "k3.1-pro",
      reasoning_enabled: true, capability: Nexus::ReasoningReplayCapability.new(format: "chat_reasoning"))
    decision = ModelReasoning::ReplayLadder.call(trace: ModelReasoning::Trace.new(envelope: envelope), target: target)
    assert_equal :native_parts, decision.kind
    part = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      native_origin: origin, payload: decision.payloads.sole)
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [part])]

    assert_equal [{ "role" => "assistant", "reasoning_content" => "inspect the file first" }],
      lower(input, model: "kimi_code/k3.1-pro")
    assert_empty lower(input, model: "kimi_code/k3.1-pro", enabled: false)
  end

  test "disabling reasoning drops opaque native items and leaves no empty assistant message" do
    origin = { "provider_id" => "anthropic", "model_id" => "claude-haiku-5-5", "api_format" => "anthropic_messages" }
    part = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      native_origin: origin, payload: { "type" => "redacted_thinking", "data" => "opaque" })
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [part])]

    assert_empty lower(input, model: "anthropic/claude-haiku-5-5", enabled: false)
  end

  test "adjacent replay segments stay apart, each native part with its origin" do
    assembly = Conversations::ContextAssembly
    segments = %w[first-model second-model].map do |model_id|
      trace = ModelReasoning::Trace.new(envelope: {
        "origin_provider_id" => "gemini", "origin_model_id" => model_id,
        "origin_api_format" => "gemini_generate_content", "origin_format_variant" => "gemini_thought",
      })
      segment = assembly::Segment.plain("assistant", model_id, trace: trace)
      decision = ModelReasoning::ReplayLadder::Decision.native_parts([{ "type" => "thought", "text" => model_id }])
      assembly::Replayed.land(segment, decision, nil)
    end

    merged = assembly.send(:merge_adjacent_roles, segments)
    assert_equal 2, merged.length, "a segment carrying reasoning never merges"
    messages = assembly.send(:materialize, merged)
    native = messages.flat_map(&:parts).select { |part| part.type == Nexus::InputParts::REASONING }
    assert_equal %w[first-model second-model], native.map { |part| part.native_origin.fetch("model_id") }
    assert_equal %w[first-model second-model], native.map { |part| part.payload.fetch("text") }
  end

  test "sealed Gemini answer parts keep their words across providers and carry signatures only on compatible requests" do
    origin = { "provider_id" => "gemini", "model_id" => "gemini-4-hydrogen", "api_format" => "gemini_generate_content" }
    parts = [["answer", "a"], ["", "b"]].map do |text, signature|
      Nexus::TextInputPart.new(type: "text", text: text, thought_signature: signature, native_origin: origin)
    end
    sealed = Nexus::InputEntries.for([Nexus::TextInputMessage.new(role: "assistant", parts: parts)])
    input = Nexus::InputEntries.from(entries: sealed, workload: "text_generation")
    assert_equal [{ "type" => "input_text", "text" => "answer", "thoughtSignature" => "a" },
      { "type" => "input_text", "text" => "", "thoughtSignature" => "b" }],
      lower(input, model: "gemini/gemini-4-carbon").sole.fetch("content")
    assert_equal [{ "type" => "input_text", "text" => "answer" }],
      lower(input, model: "openai_api/gpt-6.1-terra").sole.fetch("content")
  end

  private

    def assert_counted_text(input, model, texts, enabled: true)
      profile = DevModelLane.profile_for(model)
      selection = CountSelection.new(profile, Reasoning.new(enabled))
      assert_equal ModelRequests::TokenCount.count(profile: profile, segments: texts),
        ModelRequests::TokenCount.for_input(selection, input)
    end

    def lower(input, model:, enabled: true)
      profile = DevModelLane.profile_for(model)
      ModelRequests::Build.new(invocation: Invocation.new(reasoning_enabled: enabled),
        profile: profile, base_url: "https://example.test", host: "solid_queue")
        .send(:responses_items, input, {}, {})
    end
end
