require "test_helper"

class ModelRequests::NativeReasoningTest < ActiveSupport::TestCase
  Invocation = Data.define(:reasoning_enabled)

  test "normalization and storage retain each native reasoning value's origin" do
    origin = { "provider_id" => "openai_api", "model_id" => "gpt-6.1-sol", "api_format" => "openai_responses" }
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
      lower(input, model: "openai_api/gpt-6-luna", enabled: false)
    assert_not item.to_h.key?("native_origin")
    assert_not part.to_h.key?("native_origin")
  end

  test "unsigned Gemini thoughts stay native across its models and read as nothing across providers" do
    origin = { "provider_id" => "gemini", "model_id" => "another-gemini-model", "api_format" => "gemini_generate_content" }
    thought = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      native_origin: origin, payload: { "type" => "thought", "text" => "portable thought" })
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [thought])]

    assert_equal [thought.payload], lower(input, model: "gemini/gemini-3.8-flash").sole.fetch("content")
    assert_empty lower(input, model: "openai_api/gpt-6.1-sol"), "no fence in content, and no empty message"
  end

  # A sealed prefix follows the ladder's own rule: Anthropic's blocks pass
  # to another Anthropic model unchanged (its API drops what the model
  # cannot read), a Responses item never leaves its model.
  test "a sealed prefix passes Anthropic blocks across its models and drops a foreign Responses item" do
    opus = { "provider_id" => "anthropic", "model_id" => "claude-opus-5-5", "api_format" => "anthropic_messages" }
    block = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, native_origin: opus,
      payload: { "type" => "thinking", "thinking" => "plan", "signature" => "signed" })
    answer = Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: "answer")
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [block, answer])]

    assert_equal [block.payload, { "type" => "input_text", "text" => "answer" }],
      lower(input, model: "anthropic/claude-sonnet-5").sole.fetch("content")

    sol = { "provider_id" => "openai_api", "model_id" => "gpt-6.1-sol", "api_format" => "openai_responses" }
    item = Nexus::ReasoningInputItem.new(type: "reasoning_item", native_origin: sol,
      payload: { "type" => "reasoning", "encrypted_content" => "opaque", "summary" => [{ "type" => "summary_text", "text" => "s" }] })
    assert_equal [item.payload], lower([item], model: "openai_api/gpt-6.1-sol")
    assert_empty lower([item], model: "openai_api/gpt-6-luna"), "another model reads nothing of it"
  end

  # The chat wire carries a message's reasoning as a field of the message,
  # never a content part: the broker's detail blocks verbatim, else the
  # plain reasoning text. A round that only called tools has no words, so
  # its message is the field alone and its calls fold onto it.
  test "chat reasoning lifts onto the assistant message as its own field" do
    kimi = { "provider_id" => "openrouter", "model_id" => "moonshotai/kimi-k3", "api_format" => "openrouter_chat" }
    blocks = [{ "type" => "reasoning.text", "text" => "plan" }]
    details = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, native_origin: kimi,
      payload: { "type" => "reasoning_details", "blocks" => blocks })
    answer = Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: "answer")
    content = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, native_origin: kimi,
      payload: { "type" => "reasoning_content", "text" => "calls first" })

    assert_equal [{ "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "answer" }],
                    "reasoning_details" => blocks }],
      lower([Nexus::TextInputMessage.new(role: "assistant", parts: [details, answer])], model: "openrouter/moonshotai/kimi-k3")
    assert_equal [{ "role" => "assistant", "reasoning_content" => "calls first" }],
      lower([Nexus::TextInputMessage.new(role: "assistant", parts: [content])], model: "openrouter/moonshotai/kimi-k3")
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

  test "disabling reasoning drops opaque native items and leaves no empty assistant message" do
    origin = { "provider_id" => "anthropic", "model_id" => "claude-sonnet-5", "api_format" => "anthropic_messages" }
    part = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      native_origin: origin, payload: { "type" => "redacted_thinking", "data" => "opaque" })
    input = [Nexus::TextInputMessage.new(role: "assistant", parts: [part])]

    assert_empty lower(input, model: "anthropic/claude-sonnet-5", enabled: false)
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

  private

    def lower(input, model:, enabled: true)
      profile = DevModelLane.profile_for(model)
      ModelRequests::Build.new(invocation: Invocation.new(reasoning_enabled: enabled),
        profile: profile, base_url: "https://example.test", host: "solid_queue")
        .send(:responses_items, input, {}, {})
    end
end
