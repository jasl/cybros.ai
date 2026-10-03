require "test_helper"

class TestFinishQuality < Minitest::Test
  def test_maps_each_protocol_finish_spelling
    expected = {
      ["openai_responses", "max_output_tokens"] => "output_budget_exhausted",
      ["codex_responses", "max_output_tokens"] => "output_budget_exhausted",
      ["deepseek_responses", "max_output_tokens"] => "output_budget_exhausted",
      ["xai_responses", "max_output_tokens"] => "output_budget_exhausted",
      ["anthropic_messages", "max_tokens"] => "output_budget_exhausted",
      ["anthropic_messages", "model_context_window_exceeded"] => "context_window_exhausted",
      ["anthropic_messages", "refusal"] => "refused",
      ["gemini_generate_content", "MAX_TOKENS"] => "output_budget_exhausted",
      ["openrouter_chat", "length"] => "output_budget_exhausted",
      ["openai_compatible_chat", "length"] => "output_budget_exhausted",
    }

    expected.each do |(profile, detail), quality|
      assert_equal quality, SimpleInference::FinishQuality.for(
        adapter_profile: profile, detail: detail
      )
    end
  end

  # A classifier refusal (HTTP 200, the finish says the classifier declined)
  # is a finish the kernel must tell apart from a clean or a cut-off answer;
  # the category rides Result#refusal, not this word.
  def test_refused_is_a_persisted_quality
    assert_includes SimpleInference::FinishQuality::QUALITIES, "refused"
    assert_equal "refused", SimpleInference::FinishQuality::REFUSED
  end

  # Two declined words, typed once here: a classifier's decline (another
  # model may answer) and a content-protection stop on the content itself
  # (nobody is sent it again). Consumers read the word, never a category.
  def test_blocked_is_a_persisted_quality_beside_refused
    assert_equal "blocked", SimpleInference::FinishQuality::BLOCKED
    assert_equal %w[output_budget_exhausted context_window_exhausted refused blocked],
      SimpleInference::FinishQuality::QUALITIES
    assert_equal %w[refused blocked], SimpleInference::FinishQuality::DECLINED
  end

  RESPONSES_PROFILES = %w[openai_responses codex_responses deepseek_responses xai_responses].freeze
  CHAT_PROFILES = %w[openrouter_chat openai_compatible_chat].freeze

  def test_every_lanes_refusal_spellings_are_refused
    (RESPONSES_PROFILES + CHAT_PROFILES).product(%w[content_filter refusal]).each do |profile, detail|
      assert_equal "refused", quality(profile, detail), "#{profile} #{detail}"
    end
    assert_equal "refused", quality("anthropic_messages", "refusal")
    %w[SAFETY IMAGE_SAFETY RECITATION IMAGE_RECITATION LANGUAGE].each do |reason|
      assert_equal "refused", quality("gemini_generate_content", reason), reason
    end
    %w[SAFETY OTHER IMAGE_SAFETY JAILBREAK BLOCKED_REASON_UNSPECIFIED].each do |reason|
      assert_equal "refused", quality("gemini_generate_content", "PROMPT_#{reason}"), reason
    end
  end

  def test_gemini_content_protection_stops_are_blocked
    %w[PROHIBITED_CONTENT IMAGE_PROHIBITED_CONTENT SPII BLOCKLIST].each do |reason|
      assert_equal "blocked", quality("gemini_generate_content", reason), reason
    end
    %w[PROHIBITED_CONTENT BLOCKLIST MODEL_ARMOR].each do |reason|
      assert_equal "blocked", quality("gemini_generate_content", "PROMPT_#{reason}"), reason
    end
  end

  # Gemini's remaining non-STOP words are unclassified finishes today: no
  # quality is invented for them.
  def test_gemini_other_stays_unclassified
    %w[OTHER NO_IMAGE IMAGE_OTHER MALFORMED_FUNCTION_CALL UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS].each do |reason|
      assert_nil quality("gemini_generate_content", reason), reason
    end
  end

  def test_unknown_profile_or_detail_has_no_caveat
    assert_nil SimpleInference::FinishQuality.for(
      adapter_profile: "openai_responses", detail: "completed"
    )
    assert_nil SimpleInference::FinishQuality.for(
      adapter_profile: "future_protocol", detail: "length"
    )
    assert_nil SimpleInference::FinishQuality.for(
      adapter_profile: "openai_responses", detail: nil
    )
  end

  private

    def quality(profile, detail)
      SimpleInference::FinishQuality.for(adapter_profile: profile, detail: detail)
    end
end
