$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "stringio"
require "support/manual_openrouter_smoke"

class ManualOpenRouterSmokeTest < Minitest::Test
  Smoke = E2E::ManualOpenRouterSmoke
  ENVIRONMENT = { "RAILS_ENV" => "development", "E2E_LIVE" => "1", "OPENROUTER_API_KEY" => "private-placeholder",
                  "E2E_OPENROUTER_CHAT_MODELS" => "fixture/chat",
                  "E2E_OPENROUTER_TOOL_MODELS" => "fixture/tool",
                  "E2E_OPENROUTER_VISION_MODELS" => "fixture/vision" }.freeze

  class FixtureAdapter < SimpleInference::HTTPAdapter
    attr_reader :requests, :timeouts

    def initialize(error: nil, wrong_marker: false, wrong_prerequisites: false, incomplete_tool: false, invalid_event: nil, force_thinking: nil)
      @requests = []
      @timeouts = []
      @error = error
      @wrong_marker = wrong_marker
      @wrong_prerequisites = wrong_prerequisites
      @incomplete_tool = incomplete_tool
      @invalid_event = invalid_event
      @force_thinking = force_thinking
    end

    def call_stream(request)
      body = JSON.parse(request.fetch(:body))
      @requests << body
      @timeouts << request.fetch(:timeout)
      raise @error if @error
      if @invalid_event
        yield "data: #{@invalid_event}\n\n"
        return { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end

      messages = body.fetch("messages")
      delta, finish = answer(body, messages)
      yield "data: #{JSON.generate("provider" => "Fixture", "choices" => [{ "delta" => delta, "finish_reason" => nil }])}\n\n"
      yield "data: #{JSON.generate("choices" => [{ "delta" => {}, "finish_reason" => finish }],
        "usage" => { "prompt_tokens" => 12, "completion_tokens" => 4, "cost" => 0.0001,
                     "completion_tokens_details" => { "reasoning_tokens" => delta["reasoning_content"] ? 3 : 0 } })}\n\n"
      yield "data: [DONE]\n\n"
      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end

    private

      def answer(body, messages)
        if body["tool_choice"] == "auto"
          words = messages.map { |message| message["content"].to_s }.join(" ")
          marker = @wrong_marker ? "wrong-marker" : words[/marker-[a-f0-9]+/]
          [{ "reasoning_content" => "Use the lookup.",
             "reasoning_details" => [{ "type" => "reasoning.encrypted", "data" => "fixture-opaque" }],
             "tool_calls" => [{ "index" => 0, "id" => "fixture-call", "type" => "function",
                                "function" => { "name" => "lookup_marker", "arguments" => JSON.generate("marker" => marker) } }] },
            @incomplete_tool ? "length" : "tool_calls"]
        elsif messages.last["role"] == "tool"
          [{ "content" => JSON.parse(messages.last.fetch("content")).fetch("value") }, "stop"]
        elsif body.fetch("model") == "fixture/vision"
          content = messages.length == 2 ? (@wrong_prerequisites ? "Blue" : "Red") : "Square"
          enabled = @force_thinking.nil? ? body.dig("reasoning", "enabled") : @force_thinking
          reasoning = "The shape is red." if enabled
          [{ "content" => content, "reasoning_content" => reasoning }.compact, "stop"]
        else
          [{ "content" => @wrong_prerequisites ? "NOT_READY" : "READY", "reasoning_content" => "Remember the marker.",
             "reasoning_details" => [{ "type" => "reasoning.text", "text" => "Remember.", "signature" => "fixture-signature" }] }, "stop"]
        end
      end
  end

  def test_the_selected_cases_send_seven_bounded_requests_and_preserve_roles_reasoning_and_media
    adapter = FixtureAdapter.new
    summary, rows, output = run_smoke(adapter)
    assert_equal({ "planned" => 7, "requests" => 7, "passed" => 7, "failed" => 0, "skipped" => 0 }, summary)
    assert_equal 7, adapter.requests.length
    assert_equal [Smoke::TIMEOUT_SECONDS], adapter.timeouts.uniq
    assert adapter.requests.all? { |request| request["stream"] && request["max_tokens"] == Smoke::MAX_OUTPUT_TOKENS }
    assert adapter.requests.all? { |request| request["provider"] == { "require_parameters" => true } }
    assert_equal %w[auto none auto none], adapter.requests.filter_map { |request| request["tool_choice"] }
    assert rows.all? { |row| row["providers"] == ["Fixture"] && row.dig("usage", "input_tokens") == 12 }
    refute_includes output, ENVIRONMENT.fetch("OPENROUTER_API_KEY")

    first, second, third = adapter.requests.first(3).map { |request| request.fetch("messages") }
    assert_equal %w[system developer user], first.map { |message| message.fetch("role") }
    assert_equal %w[system developer user assistant developer user], second.map { |message| message.fetch("role") }
    assert_equal %w[system developer user assistant developer user assistant tool], third.map { |message| message.fetch("role") }
    assert_equal first, second.first(3)
    assert_equal "Remember the marker.", second.fetch(3).fetch("reasoning_content")
    assert_equal "fixture-signature", second.fetch(3).fetch("reasoning_details").first.fetch("signature")
    assert_equal second, third.first(6)
    assert_equal "fixture-opaque", third.fetch(6).fetch("reasoning_details").first.fetch("data")
    assert_equal "fixture-call", third.last.fetch("tool_call_id")

    picture, history = adapter.requests.last(2).map { |request| request.fetch("messages") }
    assert_equal picture, history.first(2)
    assert_equal "image_url", picture.last.fetch("content").last.fetch("type")
    assert_match(/\Adata:image\/png;base64,/, picture.last.fetch("content").last.dig("image_url", "url"))
    assert_equal %w[assistant user], history.last(2).map { |message| message.fetch("role") }
    refute_includes history.last.fetch("content"), "image_url"
    assert_equal [{ "enabled" => false }], adapter.requests.last(2).map { |request| request.fetch("reasoning") }.uniq
  end

  def test_a_paid_transport_failure_is_not_retried_and_skips_only_dependent_steps
    error = SimpleInference::ConnectionError.new("reset with #{ENVIRONMENT.fetch("OPENROUTER_API_KEY")}")
    adapter = FixtureAdapter.new(error: error)
    summary, rows, output = run_smoke(adapter)
    assert_equal({ "planned" => 7, "requests" => 3, "passed" => 0, "failed" => 3, "skipped" => 4 }, summary)
    assert_equal 3, adapter.requests.length
    assert_equal %w[chat_remember tool_call vision_colour], rows.reject { |row| row.key?("skipped") }.map { |row| row.fetch("case") }
    assert_includes output, "[REDACTED]"
    refute_includes output, ENVIRONMENT.fetch("OPENROUTER_API_KEY")
  end

  def test_wrong_tool_arguments_are_recorded_as_failure_without_inventing_a_successful_result
    summary, rows, = run_smoke(FixtureAdapter.new(wrong_marker: true))
    assert_equal 2, summary.fetch("failed")
    assert_equal 2, summary.fetch("skipped")
    assert_equal 5, summary.fetch("requests")
    assert_equal %w[chat_result tool_result], rows.select { |row| row.key?("skipped") }.map { |row| row.fetch("case") }
  end

  def test_wrong_prerequisite_answers_skip_dependent_paid_requests_and_keep_the_failures
    summary, rows, = run_smoke(FixtureAdapter.new(wrong_prerequisites: true))
    assert_equal({ "planned" => 7, "requests" => 4, "passed" => 2, "failed" => 2, "skipped" => 3 }, summary)
    assert_equal %w[chat_tool chat_result vision_history], rows.select { |row| row.key?("skipped") }.map { |row| row.fetch("case") }
    assert_equal %w[NOT_READY Blue], rows.select { |row| row["pass"] == false }.map { |row| row.fetch("text") }
  end

  def test_incomplete_tool_calls_cannot_satisfy_a_prerequisite_even_with_correct_arguments
    summary, rows, = run_smoke(FixtureAdapter.new(incomplete_tool: true))
    assert_equal({ "planned" => 7, "requests" => 5, "passed" => 3, "failed" => 2, "skipped" => 2 }, summary)
    failed = rows.select { |row| row["pass"] == false }
    assert_equal %w[chat_tool tool_call], failed.map { |row| row.fetch("case") }
    assert failed.all? { |row| row["finish_quality"] && row.fetch("tool_calls").length == 1 }
  end

  def test_an_explicit_diagnostic_provider_pin_is_applied_to_the_wire_and_capture_without_fallback
    adapter = FixtureAdapter.new
    summary, rows, = run_smoke(adapter, env: ENVIRONMENT.merge("E2E_OPENROUTER_PROVIDER" => "fixture/provider"))
    assert_equal 7, summary.fetch("passed")
    expected = { "require_parameters" => true, "only" => ["fixture/provider"], "allow_fallbacks" => false }
    assert_equal [expected], adapter.requests.map { |request| request.fetch("provider") }.uniq
    assert_equal [expected], rows.map { |row| row.fetch("request_body").fetch("provider") }.uniq
  end

  def test_scalar_json_events_preserve_the_original_failure_and_raw_capture_then_continue_other_models
    %w[null false "provider"].each do |event|
      adapter = FixtureAdapter.new(invalid_event: event)
      summary, rows, = run_smoke(adapter)
      assert_equal({ "planned" => 7, "requests" => 3, "passed" => 0, "failed" => 3, "skipped" => 4 }, summary)
      failed = rows.select { |row| row["pass"] == false }
      assert_equal %w[chat_remember tool_call vision_colour], failed.map { |row| row.fetch("case") }
      assert failed.all? { |row| !row.fetch("error").empty? && row["response_body"] == "data: #{event}\n\n" }
      assert failed.all? { |row| row["providers"] == [] }
    end
  end

  def test_a_reasoning_comparison_keeps_the_picture_question_and_endpoint_identical_and_changes_only_the_switch
    adapter = FixtureAdapter.new
    env = ENVIRONMENT.merge("E2E_OPENROUTER_CHAT_MODELS" => nil, "E2E_OPENROUTER_TOOL_MODELS" => nil,
      "E2E_OPENROUTER_VISION_MODELS" => nil, "E2E_OPENROUTER_REASONING_MODELS" => "fixture/vision",
      "E2E_OPENROUTER_PROVIDER" => "fixture/provider")
    summary, rows, = run_smoke(adapter, env: env)
    assert_equal({ "planned" => 2, "requests" => 2, "passed" => 2, "failed" => 0, "skipped" => 0 }, summary)
    off, on = adapter.requests
    assert_equal off.except("reasoning"), on.except("reasoning")
    assert_equal({ "enabled" => false }, off.fetch("reasoning"))
    assert_equal({ "enabled" => true }, on.fetch("reasoning"))
    assert_equal 1024, off.fetch("max_tokens")
    assert_equal ["fixture/provider"], off.fetch("provider").fetch("only")
    assert_equal({ "text_bytes" => 0, "detail_blocks" => 0, "tokens" => 0 }, rows.first.fetch("reasoning"))
    assert_operator rows.last.fetch("reasoning").fetch("text_bytes"), :>, 0
    assert_equal 3, rows.last.fetch("reasoning").fetch("tokens")

    unpinned = FixtureAdapter.new
    assert_raises(ArgumentError) { run_smoke(unpinned, env: env.merge("E2E_OPENROUTER_PROVIDER" => nil)) }
    assert_empty unpinned.requests
  end

  def test_a_provider_ignoring_the_reasoning_switch_fails_that_mode_but_both_comparison_requests_still_run
    [false, true].each do |thinking|
      adapter = FixtureAdapter.new(force_thinking: thinking)
      env = ENVIRONMENT.merge("E2E_OPENROUTER_CHAT_MODELS" => nil, "E2E_OPENROUTER_TOOL_MODELS" => nil,
        "E2E_OPENROUTER_VISION_MODELS" => nil, "E2E_OPENROUTER_REASONING_MODELS" => "fixture/vision",
        "E2E_OPENROUTER_PROVIDER" => "fixture/provider")
      summary, rows, = run_smoke(adapter, env: env)
      assert_equal({ "planned" => 2, "requests" => 2, "passed" => 1, "failed" => 1, "skipped" => 0 }, summary)
      assert_equal [thinking ? "reasoning_off" : "reasoning_on"], rows.select { |row| row["pass"] == false }.map { |row| row.fetch("case") }
    end
  end

  def test_all_paid_preconditions_are_checked_before_the_transport
    [{ "E2E_LIVE" => nil }, { "CI" => "true" }, { "RAILS_ENV" => "test" }, { "OPENROUTER_API_KEY" => nil },
     { "E2E_OPENROUTER_CHAT_MODELS" => nil, "E2E_OPENROUTER_TOOL_MODELS" => nil, "E2E_OPENROUTER_VISION_MODELS" => nil }].each do |override|
      adapter = FixtureAdapter.new
      assert_raises(ArgumentError) { run_smoke(adapter, env: ENVIRONMENT.merge(override)) }
      assert_empty adapter.requests
    end
  end

  private

    def run_smoke(adapter, env: ENVIRONMENT)
      output = StringIO.new
      summary = Smoke.new(env: env, output: output, adapter: adapter).run
      rows = output.string.lines.map { |line| JSON.parse(line) }.reject { |row| row.key?("summary") }
      [summary, rows, output.string]
    end
end
