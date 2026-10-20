require "json"
require "test_helper"

class TestChatDeveloperRole < Minitest::Test
  def test_declared_role_maps_instructions_in_place_without_changing_the_source_or_tool_round
    input = [
      { role: "system", content: "Base." },
      { role: "developer", content: "Environment." },
      { role: "user", content: "Question." },
      { role: "assistant", content: "Checking.", reasoning_content: "Thought." },
      { type: "function_call", call_id: "call_1", name: "lookup", arguments: "{}" },
      { type: "function_call_output", call_id: "call_1", output: "Result." },
      { role: "developer", content: "Updated environment." },
      { role: "user", content: "Next question." },
    ]
    snapshot = Marshal.dump(input)

    [false, true].each do |stream|
      body = compile(input, role: "system", stream: stream)
      messages = body.fetch("messages")
      assert_equal %w[system system system user assistant tool system user], messages.map { |message| message.fetch("role") }
      assert_equal "Separate instructions.", messages[0].fetch("content")
      assert_equal "Environment.", messages[2].fetch("content")
      assert_equal "Updated environment.", messages[6].fetch("content")
      assert_equal "Thought.", messages[4].fetch("reasoning_content")
      assert_equal 1, messages[4].fetch("tool_calls").length
      assert_equal "call_1", messages[4].fetch("tool_calls").first.fetch("id")
      assert_equal "call_1", messages[5].fetch("tool_call_id")
      assert_equal "Result.", messages[5].fetch("content")
      refute body.key?("developer_role")
      assert_equal snapshot, Marshal.dump(input)

      [nil, "developer"].each do |role|
        unchanged = compile(input, role: role, stream: stream).fetch("messages")
        assert_equal %w[system system developer user assistant tool developer user], unchanged.map { |message| message.fetch("role") }
      end
    end
  end

  def test_invalid_roles_and_other_protocols_reject_the_option_before_io
    ["user", "unknown", false].each do |role|
      assert_raises(SimpleInference::ConfigurationError) { profile_for("openai_compatible_chat", wire_options: { developer_role: role }) }
      assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::Protocols::OpenAICompatibleResponses.new(base_url: "https://example.com", developer_role: role)
      end
    end
    assert_raises(SimpleInference::ConfigurationError) { profile_for("openai_responses", wire_options: { developer_role: "system" }) }
  end

  private

  def compile(input, role:, stream:)
    profile = profile_for("openai_compatible_chat", wire_options: { developer_role: role })
    client = SimpleInference::Client.new(execution_profile: profile, base_url: "https://example.com")
    request = client.responses.compile(model: profile.model_pin, input: input,
      instructions: "Separate instructions.", stream: stream)
    JSON.parse(request.payload)
  end
end
