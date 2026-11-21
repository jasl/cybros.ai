require "json"
require "test_helper"

class TestPromptCacheTTL < Minitest::Test
  FORMATS = %w[openai_responses openai_compatible_chat openrouter_chat].freeze

  def test_request_lifetimes_lower_on_unary_and_streaming_wires_without_changing_the_prompt
    FORMATS.each do |format|
      [false, true].each do |stream|
        baseline = body(format, stream: stream)
        { "30m" => { "prompt_cache_options" => { "ttl" => "30m" } },
          "12h" => { "prompt_cache_options" => { "ttl" => "12h" } },
          "24h" => { "prompt_cache_retention" => "24h" } }.each do |ttl, fields|
          assert_equal baseline.merge(fields), body(format, stream: stream, prompt_cache_ttl: ttl), "#{format}: #{ttl}"
        end
      end
    end
  end

  def test_omission_does_not_add_cache_fields_and_invalid_values_fail_before_io
    FORMATS.each do |format|
      assert_equal body(format), body(format, prompt_cache_ttl: nil)
      invalid = format == "openrouter_chat" ? %w[2d bad] : %w[5m 1h 2d bad]
      invalid.each do |ttl|
        assert_raises(SimpleInference::ValidationError) { body(format, prompt_cache_ttl: ttl) }
      end
    end
  end

  def test_openrouter_anthropic_ttls_apply_one_automatic_breakpoint_at_the_root
    [false, true].each do |stream|
      baseline = body("openrouter_chat", stream: stream)
      { "5m" => { "type" => "ephemeral" }, "1h" => { "type" => "ephemeral", "ttl" => "1h" } }.each do |ttl, marker|
        assert_equal baseline.merge("cache_control" => marker), body("openrouter_chat", stream: stream, prompt_cache_ttl: ttl)
      end
    end
  end

  def test_other_response_dialects_do_not_inherit_an_unverified_cache_control
    %w[codex_responses deepseek_responses xai_responses].each do |format|
      assert_raises(SimpleInference::ValidationError) { body(format, stream: true, prompt_cache_ttl: "12h") }
    end
  end

  private

  def body(format, stream: false, **options)
    profile = profile_for(format)
    client = SimpleInference::Client.new(base_url: "https://example.test", execution_profile: profile)
    JSON.parse(client.responses.compile(model: profile.model_pin,
      input: [{ role: "user", content: "hello" }], stream: stream, **options).payload)
  end
end
