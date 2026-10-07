require "json"
require "test_helper"

class TestPromptFormat < Minitest::Test
  FORMATS = %w[openai_compatible_chat openrouter_chat openai_responses].freeze

  def test_profile_accepts_the_declared_format_and_rejects_an_unknown_one
    assert_equal "qwen3_5", profile.wire_option(:prompt_format)
    assert_nil profile(prompt_format: nil).wire_option(:prompt_format)
    assert_nil profile_for("openai_compatible_chat", wire_options: { prompt_format: nil }).wire_option(:prompt_format)

    error = assert_raises(SimpleInference::ConfigurationError) { profile(prompt_format: "unknown") }
    assert_includes error.message, "prompt_format"
    assert_includes error.message, "qwen3_5"
  end

  def test_default_format_preserves_input_and_separate_instructions
    input = [{ role: "system", content: "base" }, { role: "developer", content: "local" }]
    instructions = "separate"
    projected, options = project(input, instructions: instructions, prompt_format: nil)

    assert_same input, projected
    assert_same instructions, options.fetch(:instructions)
  end

  def test_instructions_and_leading_system_developer_messages_form_one_ordered_system
    input = [
      { role: "system", content: "base" },
      { "role" => "developer", "content" => [{ "type" => "input_text", "text" => "local" }] },
      { role: "system", content: [{ type: "text", text: "last" }] },
      { role: "user", content: "question" },
    ]
    snapshot = Marshal.dump(input)
    freeze_tree(input)
    projected, options = project(input, instructions: "separate".freeze)

    assert_equal %w[system user], projected.map { |message| message.fetch("role") }
    assert_equal "separate\n\nbase\n\nlocal\n\nlast", instruction_text(projected.first)
    refute options.key?(:instructions)
    assert_equal snapshot, Marshal.dump(input)
  end

  def test_mid_conversation_instructions_keep_their_position_and_never_join_the_prefix
    input = [
      { role: "system", content: "base" },
      { role: "user", content: "question" },
      { role: "assistant", content: "answer" },
      { role: "developer", content: "changed" },
      { role: "system", content: "fresh" },
      { role: "user", content: "next" },
    ]
    projected, = project(input)

    assert_equal %w[system user assistant user user user], projected.map { |message| message.fetch("role") }
    assert_equal "base", instruction_text(projected.first)
    assert_equal %w[question answer changed fresh next], projected.drop(1).map { |message| message.fetch("content") }
  end

  def test_string_and_string_list_inputs_keep_their_text
    projected, options = project("question", instructions: "base")
    assert_equal ["base", "question"], projected.map { |message| instruction_text(message) }
    refute options.key?(:instructions)

    projected, = project(["first", { role: "developer", content: "local" }, "last"])
    assert_equal %w[user user user], projected.map { |message| message.fetch("role") }
    assert_equal %w[first local last], projected.map { |message| message.fetch("content") }
  end

  def test_projection_preserves_media_tool_pairs_and_reasoning_without_mutating_nested_values
    media = SimpleInference::MediaInput.new(media_type: "image/png", bytes: "image bytes")
    calls = [{ id: "call_1", type: "function", function: { name: "lookup", arguments: "{}" } }]
    reasoning = { type: "reasoning", id: "rs_1", encrypted_content: "opaque", summary: [] }
    input = [
      { role: "system", content: "base" },
      { role: "user", content: [{ type: "input_text", text: "look" }, { type: "input_image", image_url: media }] },
      reasoning,
      { role: "assistant", content: "checking", reasoning_content: "thought", tool_calls: calls },
      { type: "function_call", call_id: "call_2", name: "lookup", arguments: "{}" },
      { role: "tool", tool_call_id: "call_1", content: "first result" },
      { type: "function_call_output", call_id: "call_2", output: "second result" },
      { role: "developer", content: "continue" },
    ]
    before = Marshal.dump(input)
    freeze_tree(input)
    projected, = project(input)

    assert_equal input[1].fetch(:content), projected[1].fetch("content")
    assert_equal calls, projected[3].fetch("tool_calls")
    assert_equal "thought", projected[3].fetch("reasoning_content")
    assert_equal reasoning.transform_keys(&:to_s), projected[2]
    assert_equal input[4].transform_keys(&:to_s), projected[4]
    assert_equal input[5].transform_keys(&:to_s), projected[5]
    assert_equal input[6].transform_keys(&:to_s), projected[6]
    assert_equal "user", projected[7].fetch("role")
    assert_equal before, Marshal.dump(input)
  end

  def test_non_text_leading_instruction_content_is_rejected_instead_of_dropped_or_moved
    image = { type: "input_image", image_url: SimpleInference::MediaInput.new(media_type: "image/png", bytes: "image") }
    input = [{ role: "system", content: [image] }, { role: "user", content: "question" }]
    error = assert_raises(SimpleInference::ValidationError) { project(input) }
    assert_includes error.message, "instruction content must contain only text"
  end

  def test_media_in_a_later_instruction_stays_in_its_user_message_after_projection
    media = SimpleInference::MediaInput.new(media_type: "image/png", bytes: "image")
    input = [
      { role: "user", content: "question" },
      { role: "developer", content: [{ type: "input_image", image_url: media }] },
    ]
    freeze_tree(input)
    projected, = project(input)
    assert_equal %w[user user], projected.map { |message| message.fetch("role") }
    assert_equal input[1].fetch(:content), projected[1].fetch("content")

    messages = compile(input, format: "openai_compatible_chat").fetch("messages")
    assert_equal "data:image/png;base64,#{[media.bytes].pack("m0")}", messages[1].dig("content", 0, "image_url", "url")
  end

  def test_reapplying_the_projection_does_not_duplicate_or_reorder_instructions
    input = [{ role: "system", content: "base" }, { role: "developer", content: "local" }, { role: "user", content: "question" }]
    projected, options = project(input, instructions: "separate")
    selected = profile
    repeated, repeated_options = SimpleInference::Planning::RequestValidator.validate_responses_request(
      profile: selected, model: selected.model_pin, input: projected, options: options, streaming: false
    )

    assert_equal projected, repeated
    assert_equal options, repeated_options
  end

  def test_resource_compilers_apply_the_same_layout_for_streaming_and_unary_requests
    input = [
      { role: "system", content: "base" },
      { role: "developer", content: "local" },
      { role: "user", content: "question" },
      { role: "assistant", content: "answer" },
      { role: "developer", content: "changed" },
      { role: "user", content: "next" },
    ]
    FORMATS.each do |format|
      [false, true].each do |stream|
        body = compile(input, format: format, stream: stream, instructions: "separate")
        messages = body.fetch(format == "openai_responses" ? "input" : "messages")
        assert_equal %w[system user assistant user user], messages.map { |message| message.fetch("role") }, format
        assert_equal "separate\n\nbase\n\nlocal", instruction_text(messages.first), format
        assert_equal "changed", messages[3].fetch("content"), format
        refute body.key?("instructions"), format
        refute body.key?("prompt_format"), format
      end
    end
  end

  def test_recompiling_the_same_input_for_another_model_does_not_carry_the_first_models_projection
    input = [
      { role: "system", content: "base" },
      { role: "developer", content: "local" },
      { role: "user", content: "question" },
      { role: "assistant", content: "answer" },
      { role: "developer", content: "changed" },
    ]
    freeze_tree(input)
    adapted = compile(input, format: "openai_compatible_chat", instructions: "separate")
    unchanged = compile(input, format: "openai_compatible_chat", instructions: "separate", prompt_format: nil)
    retried = compile(input, format: "openai_compatible_chat", instructions: "separate")

    assert_equal %w[system user assistant user], adapted.fetch("messages").map { |message| message.fetch("role") }
    assert_equal %w[system system developer user assistant developer], unchanged.fetch("messages").map { |message| message.fetch("role") }
    assert_equal adapted, retried
    assert_equal %w[system developer user assistant developer], input.map { |message| message.fetch(:role) }
  end

  def test_compiled_media_and_tool_results_stay_in_place
    media = SimpleInference::MediaInput.new(media_type: "image/png", bytes: "image bytes")
    input = [
      { role: "system", content: "base" },
      { role: "developer", content: "local" },
      { role: "user", content: [{ type: "input_image", image_url: media }] },
      { role: "assistant", content: "checking", reasoning_content: "thought" },
      { type: "function_call", call_id: "call_1", name: "lookup", arguments: "{}" },
      { type: "function_call_output", call_id: "call_1", output: "result" },
      { role: "developer", content: "continue" },
    ]
    freeze_tree(input)
    %w[openai_compatible_chat openrouter_chat].each do |format|
      body = compile(input, format: format)
      messages = body.fetch("messages")
      assert_equal %w[system user assistant tool user], messages.map { |message| message.fetch("role") }
      assert_equal "data:image/png;base64,#{[media.bytes].pack("m0")}", messages[1].dig("content", 0, "image_url", "url")
      assert_equal "thought", messages[2].fetch("reasoning_content")
      assert_equal "call_1", messages[2].dig("tool_calls", 0, "id")
      assert_equal "result", messages[3].fetch("content")
      assert_equal "continue", messages[4].fetch("content")
    end

    messages = compile(input, format: "openai_responses").fetch("input")
    assert_equal "input_image", messages[1].dig("content", 0, "type")
    assert_equal "data:image/png;base64,#{[media.bytes].pack("m0")}", messages[1].dig("content", 0, "image_url")
    assert_equal "function_call", messages[3].fetch("type")
    assert_equal "function_call_output", messages[4].fetch("type")
    assert_equal "user", messages[5].fetch("role")
  end

  private

  def profile(format: "openai_compatible_chat", prompt_format: "qwen3_5")
    options = SimpleInference::ApiFormat.defaults(format).fetch(:wire_options).merge(prompt_format: prompt_format).compact
    profile_for(format, wire_options: options)
  end

  def project(input, instructions: nil, prompt_format: "qwen3_5")
    selected = profile(prompt_format: prompt_format)
    SimpleInference::Planning::RequestValidator.validate_responses_request(
      profile: selected, model: selected.model_pin, input: input,
      options: { instructions: instructions }, streaming: false
    )
  end

  def compile(input, format:, stream: false, instructions: nil, prompt_format: "qwen3_5")
    selected = profile(format: format, prompt_format: prompt_format)
    client = SimpleInference::Client.new(base_url: "http://example.com", execution_profile: selected)
    JSON.parse(client.responses.compile(model: selected.model_pin, input: input, stream: stream, instructions: instructions).payload)
  end

  def instruction_text(message)
    content = message.fetch("content")
    case content
    in String then content
    in Array then content.map { |part| part.fetch("text") }.join
    else raise "unexpected content in test: #{content.inspect}"
    end
  end

  def freeze_tree(value)
    case value
    in Hash then value.each { |key, entry| freeze_tree(key); freeze_tree(entry) }
    in Array then value.each { |entry| freeze_tree(entry) }
    else nil
    end
    value.freeze
  end
end
