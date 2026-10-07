require_relative "test_helper"
require_relative "../support/mock_llm/directives"

# The `!mock` grammar is the fake provider's whole control surface, so it is
# tested apart from any HTTP: a journey that says `!mock error=503` is making
# a claim about this parser, and a parser that quietly treated the typo
# `!mock erorr=503` as a prompt would let that journey pass while exercising
# the opposite of its name.
class MockLLMDirectivesTest < Minitest::Test
  Directives = E2E::MockLLM::Directives

  def test_a_prompt_without_the_marker_is_a_prompt
    controls = Directives.parse("summarise this")

    assert_equal "summarise this", controls.prompt
    refute_predicate controls, :error?
    assert_nil controls.slow_seconds
    assert_nil controls.usage
  end

  def test_an_empty_prompt_takes_the_default
    assert_equal "Hello", Directives.parse("   ").prompt
    assert_equal "Hello", Directives.parse("!mock").prompt
  end

  def test_directives_and_an_inline_prompt_split_on_the_separator
    controls = Directives.parse("!mock usage=10:20 -- describe the photo")

    assert_equal "describe the photo", controls.prompt
    assert_equal({ "prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30 },
                 controls.usage)
  end

  def test_the_prompt_may_follow_on_later_lines
    controls = Directives.parse("!mock slow=0.05\nline one\nline two")

    assert_equal "line one\nline two", controls.prompt
    assert_in_delta 0.05, controls.slow_seconds
  end

  def test_a_body_opening_with_the_separator_is_all_prompt
    assert_equal "just this", Directives.parse("!mock -- just this").prompt
  end

  def test_error_and_fail_are_the_same_directive
    %w[error fail].each do |key|
      controls = Directives.parse("!mock #{key}=503")

      assert_predicate controls, :error?
      assert_equal 503, controls.error_status
      refute controls.error_includes_usage
    end
  end

  # The distinction settlement cares about: a provider that charged and then
  # failed is not the same as one that refused.
  # THE FLOOR'S HEADER (the provider admission floor, 2026-09-15): the
  # kernel floors a lane from `Retry-After`, so a journey must be able to
  # script one — and only beside an error, or the script says nothing.
  def test_retry_after_rides_a_scripted_error_and_refuses_without_one
    controls = Directives.parse("!mock error=429 retry_after=10")

    assert_equal 429, controls.error_status
    assert_equal 10, controls.retry_after_seconds
    assert_nil Directives.parse("!mock error=503").retry_after_seconds

    error = assert_raises(Directives::Invalid) { Directives.parse("!mock retry_after=10") }
    assert_match(/retry_after needs error/, error.message)
    assert_raises(Directives::Invalid) { Directives.parse("!mock error=429 retry_after=soon") }
    assert_raises(Directives::Invalid) { Directives.parse("!mock error=429 retry_after=1.5") }
  end

  def test_fail_after_usage_marks_the_error_as_billed
    controls = Directives.parse("!mock fail_after_usage=500 message=boom")

    assert_equal 500, controls.error_status
    assert controls.error_includes_usage
    assert_equal "boom", controls.error_message
  end

  def test_error_model_limits_a_refusal_to_the_named_wire_model
    controls = Directives.parse("!mock error=401 error_model=mock-text -- receipt")

    assert_equal "mock-text", controls.error_model
    assert controls.error_for?("mock-text")
    refute controls.error_for?("mock-text-only")
    assert_equal "receipt", controls.prompt
    assert Directives.parse("!mock error=403").error_for?("mock-text-only")
    refute Directives.parse("!mock -- receipt").error_for?("mock-text")

    error = assert_raises(Directives::Invalid) { Directives.parse("!mock error_model=mock-text") }
    assert_equal "error_model needs error", error.message
  end

  def test_reasoning_is_url_decoded
    controls = Directives.parse("!mock reasoning=step%20one%20then%20two")

    assert_equal "step one then two", controls.reasoning
  end

  # A mistyped directive must not degrade into a happy path.
  def test_unknown_and_malformed_directives_refuse
    [
      "!mock erorr=503",
      "!mock error=99",
      "!mock error=abc",
      "!mock slow=-1",
      "!mock slow=",
      "!mock usage=10",
      "!mock usage=a:b",
      "!mock reasoning=",
    ].each do |line|
      assert_raises(Directives::Invalid, line) { Directives.parse(line) }
    end
  end

  # A mistyped `slow=600` must not be able to hang a suite.
  def test_delays_are_clamped
    assert_in_delta 0.2, Directives.parse("!mock slow=600").slow_seconds
    assert_in_delta 0.2, Directives.parse("!mock stream_chunk_delay=600").stream_chunk_delay_seconds
    assert_in_delta 5.0, Directives.parse("!mock slow=600", max_slow_seconds: 5.0).slow_seconds
  end

  def test_content_echoes_the_prompt_and_honours_markdown_mode
    assert_equal "Mock: hello", Directives.content_for("hello")
    assert_equal "Mock: Hello", Directives.content_for("  ")

    markdown = Directives.content_for("!md the subject")
    assert_includes markdown, "# Mock Markdown"
    assert_includes markdown, "**Prompt:** the subject"
  end

  # Four characters to the token, rounded up, on both sides — deterministic
  # so a settlement test can predict the number.
  def test_usage_is_a_deterministic_character_estimate
    usage = Directives.usage_for("12345678", "123")

    assert_equal 2, usage.fetch("prompt_tokens")
    assert_equal 1, usage.fetch("completion_tokens")
    assert_equal 3, usage.fetch("total_tokens")
  end

  # A SCRIPTED REPLY, for the one request an echo can prove nothing about:
  # a summarizer's answer is by construction the size of what it read, so
  # an echoed "summary" can never make the retry fit. `reply=` makes the
  # fake speak the given text; the echo — the kept prompt — is untouched,
  # so the usage estimate and the marker-line rules read as before.
  def test_a_scripted_reply_is_spoken_instead_of_the_echo
    controls = Directives.parse("history\n!mock reply=THE+SUMMARY -- turn4 body")

    assert_equal "THE SUMMARY", controls.reply
    assert_equal "THE SUMMARY", controls.spoken
    assert_equal "history\nturn4 body", controls.prompt, "the echo is still the kept prompt"
    assert_equal "Mock: THE SUMMARY", Directives.content_for(controls.spoken)
    assert_nil Directives.parse("plain").reply
    assert_equal "plain", Directives.parse("plain").spoken
    assert_raises(Directives::Invalid) { Directives.parse("!mock reply=") }
    assert_raises(Directives::Invalid) { Directives.parse("!mock reply=%20") }
  end

  def test_scoped_echo_is_explicit_and_a_later_marker_clears_it
    %w[images content request].each do |mode|
      controls = Directives.parse("system lead\n!mock echo=#{mode} -- inspect the content")
      assert_equal mode, controls.echo
      assert_equal "system lead\ninspect the content", controls.prompt
      assert_nil Directives.parse("!mock echo=#{mode} -- first\n!mock -- second").echo
    end
    assert_nil Directives.parse("plain prompt").echo
    assert_raises(Directives::Invalid) { Directives.parse("!mock echo=text") }
  end

  def test_a_literal_reply_can_be_scripted_in_a_quoted_message
    answer = JSON.generate("decision" => "reply", "text" => "A useful answer")
    message = JSON.generate("role" => "user", "text" => "Discuss this.\n!mock raw_reply=#{CGI.escape(answer)} stream_chunk_delay=0.1")
    controls = Directives.parse("Quoted discussion:\n#{message}")

    assert_equal answer, controls.raw_reply
    assert_in_delta 0.1, controls.stream_chunk_delay_seconds
    assert_nil Directives.parse("plain").raw_reply
    assert_nil Directives.parse("#{message}\n!mock -- clear").raw_reply
    assert_raises(Directives::Invalid) { Directives.parse("!mock raw_reply=%20") }
  end

  def test_a_literal_reply_can_be_scripted_in_a_quoted_source_prompt
    answer = JSON.generate("content" => "Stable notes", "summary" => "Reviewed a patch")
    source = JSON.generate("prompt" => "!mock raw_reply=#{CGI.escape(answer)} -- Review the patch.", "answer" => answer)

    assert_equal answer, Directives.parse("Quoted source:\n#{source}").raw_reply
    assert_nil Directives.parse("#{source}\n!mock -- clear").raw_reply
  end

  # A `+` joins a GROUP — one round's whole fan (two captures must arrive in one round) — and the
  # groups are spent by their size: two answers move past a two-call group, one answer inside it
  # speaks. A lone name is a group of one, as every script was.
  def test_an_ampersand_joins_a_group_the_round_makes_at_once
    controls = Directives.parse(
      "!mock tool_call=capture&capture:%7B%22n%22%3A2%7D,bash tool_args=%7B%22a%22%3A1%7D -- go"
    )

    assert_equal [%w[capture capture], %w[bash]], controls.tool_calls.map { |group| group.map(&:name) }
    assert_equal ['{"a":1}', '{"n":2}'], controls.tool_calls.first.map(&:arguments),
      "the default reaches a group's members; a member's own arguments stand"
    assert_equal %w[capture capture], controls.tool_calls_at(0).map(&:name)
    assert_nil controls.tool_calls_at(1), "an answer count inside a group speaks"
    assert_equal %w[bash], controls.tool_calls_at(2).map(&:name)
    assert_nil controls.tool_calls_at(3), "past the end it speaks"
    lone = Directives.parse("!mock tool_call=read,bash")
    assert_equal [%w[read], %w[bash]], lone.tool_calls.map { |group| group.map(&:name) }
    assert_equal %w[bash], lone.tool_calls_at(1).map(&:name)
  end

  # The agent-loop responders are deliberately absent: they drive a tool round
  # for a consumer this rewrite does not have yet.
  def test_the_agent_run_directives_are_not_ported
    assert_raises(Directives::Invalid) { Directives.parse("!mock tool_calls=%5B%5D") }
  end

  # THE LAST `!mock` LINE WINS. The fake reads the whole joined input — a system lead, the history,
  # the prompt, a trailing steer — and the marker nearest the end is the one speaking for THIS
  # round: a continuation replays round one's prompt line, so its script advances by the answers
  # already present rather than by a second marker; a steer or a later prompt carrying its own line
  # overrides. Every marker line leaves the echo as its inline remainder, so no later turn's history
  # carries a directive it did not type.
  def test_the_last_marker_line_wins_over_an_earlier_one
    controls = Directives.parse("!mock error=500 -- a\nMock: a\n!mock -- b")

    refute_predicate controls, :error?
    assert_equal "a\nMock: a\nb", controls.prompt
  end

  # rho opens every turn with an inline system lead AHEAD of the prompt.
  def test_a_marker_below_a_system_lead_is_read
    controls = Directives.parse("lead\n!mock usage=1:2 -- p")

    assert_equal({ "prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3 }, controls.usage)
    assert_equal "lead\np", controls.prompt
  end

  # A bare `!mock --` after a scripted line clears every directive for the
  # round: the way a later turn says "inherit nothing" regardless of what the
  # lead or the history ahead of it carries.
  def test_a_bare_marker_after_a_scripted_line_clears_it
    controls = Directives.parse("!mock tool_call=read -- go\n!mock --")

    assert_nil controls.tool_calls
    refute_predicate controls, :error?
    assert_equal "go", controls.prompt
  end
end
