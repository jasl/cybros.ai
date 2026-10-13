require "json"
require "test_helper"

class TestCodexMedia < Minitest::Test
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "prepared-test-pixels".b).freeze

  def test_compiled_role_only_messages_lower_image_bytes_in_classic_and_lite_requests
    [false, true].each do |lite|
      media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
      input = [{ "role" => "user", "content" => [
        { "type" => "input_text", "text" => "describe" },
        { "type" => "input_image", "image_url" => media, "detail" => "high" },
      ] }]

      compiled = client(lite: lite).responses.compile(model: "vision-model", input: input, stream: true)
      body = JSON.parse(compiled.payload)
      message = body.fetch("input").find { |item| item["role"] == "user" }
      expected_image = { "type" => "input_image", "image_url" => "data:image/png;base64,#{[PNG_BYTES].pack("m0")}" }
      expected_image["detail"] = "high" unless lite

      assert_equal "/responses", compiled.path
      assert_equal({ "role" => "user", "content" => [
        { "type" => "input_text", "text" => "describe" }, expected_image,
      ] }, message)
    end
  end

  def test_role_only_messages_cannot_bypass_the_bytes_only_guard_with_caller_urls
    [false, true].each do |lite|
      input = [{ role: "user", content: [{ type: "input_image", image_url: "https://example.com/image.png" }] }]

      error = assert_raises(SimpleInference::ValidationError) do
        client(lite: lite).responses.compile(model: "vision-model", input: input, stream: true)
      end
      assert_includes error.message, "MediaInput"
    end
  end

  private

  def client(lite:)
    defaults = SimpleInference::ApiFormat.defaults("codex_responses")
    profile = profile_for("codex_responses", model_pin: "vision-model",
      wire_options: defaults.fetch(:wire_options).merge(use_responses_lite: lite))
    SimpleInference::Client.new(execution_profile: profile, base_url: "https://example.test")
  end
end
