require_relative "test_helper"
require "json"
require "stringio"
require "simple_inference"
require_relative "../support/mock_llm/app"

# THE CONTRACT THAT ACTUALLY MATTERS: the vendored parser reads this stream.
#
# `mock_llm_app_test.rb` asserts the shapes I intended to emit, which is worth
# having and is not proof of anything — a mock whose event names are subtly
# wrong passes its own assertions perfectly and then feeds a send path that
# extracts nothing. So these drive the fake provider's real output through
# `SimpleInference::Protocols::OpenAIResponses`'s own extraction points, the
# four pure functions its streaming accumulator is built from.
#
# The methods are private, which is the honest reason to reach for `send`
# here rather than restate their logic: a copy would agree with itself while
# disagreeing with the parser, and the parser is the party whose opinion
# decides whether a real send works.
class MockLLMWireContractTest < Minitest::Test
  PARSER = SimpleInference::Protocols::OpenAIResponses.allocate
  # A request that means to be answered with a call DECLARES its tools, as
  # the kernel's rounds do (`tools` is a request fact): the fake calls only
  # what was declared, the way every real provider does.
  TOOLS = [{ "type" => "function", "name" => "bash", "parameters" => {} }].freeze

  def setup
    @app = E2E::MockLLM::App.new(clock: Class.new { def sleep(_) = nil }.new)
  end

  def test_the_parser_reassembles_the_text_the_mock_meant_to_send
    events = stream(input: "say hi")

    text = events.filter_map { PARSER.send(:output_text_delta, _1) }.join

    assert_equal "Mock: say hi", text,
      "the parser's own delta extraction has to see the whole message"
  end

  def test_the_parser_finds_usage_exactly_once_and_on_the_terminal
    events = stream(input: "!mock usage=7:5 -- hi")

    carriers = events.filter_map { |event| PARSER.send(:usage_from_event, event) }

    assert_equal 1, carriers.length, "usage is terminal-only on this wire"
    assert_equal({ "input_tokens" => 7, "output_tokens" => 5, "total_tokens" => 12 },
                 carriers.first)
  end

  def test_the_parser_recognises_the_terminal_body
    events = stream(input: "say hi")

    bodies = events.filter_map { PARSER.send(:terminal_response_body_from_event, _1) }

    assert_equal 1, bodies.length, "exactly one event closes the stream"
    assert_equal "completed", bodies.first.fetch("status")
    assert_equal "Mock: say hi", bodies.first.dig("output", 0, "content", 0, "text")
  end

  # A stream with no terminal event is what the parser refuses, so a mock that
  # forgot to emit one would strand every send until its deadline. Proving the
  # terminal is THERE is proving that cannot happen.
  def test_every_shipped_text_model_terminates_its_stream
    %w[mock-text mock-unmetered mock-priced].each do |model|
      bodies = stream(model: model, input: "hi")
        .filter_map { PARSER.send(:terminal_response_body_from_event, _1) }

      assert_equal 1, bodies.length, "#{model} must close its stream"
    end
  end

  def test_the_parser_reads_reasoning_deltas_under_a_kind_it_knows
    events = stream(input: "!mock reasoning=weighing%20it -- answer")

    reasoning = events.filter_map { PARSER.send(:reasoning_delta_from_event, _1) }

    refute_empty reasoning, "the mock must use a delta type the parser maps to a kind"
    assert_equal ["reasoning_text"], reasoning.map { _1[:kind] }.uniq
    assert_equal "weighing it", reasoning.map { _1[:delta] }.join
  end

  # A billed failure is correctly represented only if the parser sees BOTH facts: that it failed,
  # and that it was charged.
  def test_a_billed_failure_carries_its_usage_to_the_parser
    events = stream(input: "!mock fail_after_usage=500 usage=9:0")

    failed = events.find { _1["type"] == "response.failed" }
    refute_nil failed, "a billed failure stays on the stream"
    assert_equal 9, failed.dig("response", "usage", "input_tokens")
    assert_empty events.filter_map { PARSER.send(:terminal_response_body_from_event, _1) },
      "a failure is not a terminal RESPONSE body: it must not read as a completed one"
  end

  # THE PAIRED TOOL ROUND'S FIRST HALF. The parser assembles a call from
  # the STREAM — the announced item supplies its identifiers, the argument
  # frames supply its body — and reconciles the result against the terminal
  # body positionally. A mock that emitted only one half would produce a
  # call with no id or no arguments: a shape no real provider sends, and
  # one that would strand the kernel's fan.
  def test_the_parser_assembles_the_tool_call_the_mock_meant_to_make
    events = stream(input: "!mock tool_call=bash tool_args=%7B%22command%22%3A%22ls%22%7D", tools: TOOLS)

    states = {}
    order = []
    events.each { |event| PARSER.send(:collect_output_item_event, event, states: states, order: order) }
    calls = events.filter_map { PARSER.send(:stream_tool_call_event, _1, states: states) }

    done = calls.find { |event| event.is_a?(SimpleInference::Responses::Events::ToolCallDone) }
    refute_nil done, "the arguments must close, or nothing knows the call is complete"
    assert_equal "bash", done.name
    refute_empty done.call_id.to_s, "a call nobody can address is a call nobody can answer"
    assert_equal %({"command":"ls"}), done.arguments

    # AND THE ASSEMBLED ITEM, which is what the kernel's fan actually
    # reads: the stream's state reconciled against the terminal body.
    bodies = events.filter_map { PARSER.send(:terminal_response_body_from_event, _1) }
    assert_equal 1, bodies.length
    items = PARSER.send(
      :merge_stream_output_items_with_body,
      PARSER.send(:finalize_stream_output_items, states, order),
      bodies.first.fetch("output")
    )
    assert_equal 1, items.length
    assembled = items.first
    assert_equal "function_call", assembled.fetch("type"),
      "a round answers with text OR a call, never both"
    assert_equal "bash", assembled.fetch("name")
    assert_equal %({"command":"ls"}), assembled.fetch("arguments")
    refute_empty assembled.fetch("call_id").to_s

    # ONE call_id ON BOTH FRAMES. Two, reconciled positionally, is a shape
    # production never produces — so the parser's id-matching arm would
    # never run here, and any consumer correlating the live narration with
    # the persisted graph by call id would mismatch under e2e and only
    # under e2e.
    added = events.find { _1["type"] == "response.output_item.added" }
    assert_equal added.dig("item", "call_id"), bodies.first.dig("output", 0, "call_id"),
      "the stream item and the terminal body must name the same call"
    assert_equal added.dig("item", "call_id"), done.call_id
  end

  # A TOOL RESULT WAS INVISIBLE TO THE MOCK. `prompt_from_input` read
  # text/content/input and a `function_call_output` carries `output`, so a
  # tool result contributed NOTHING to the prompt — and the fake echoes its
  # prompt, which means no journey could ever observe what the model was
  # shown. That is the one thing the whole tool protocol delivers.
  def test_the_mock_sees_a_tool_result_in_its_input
    events = stream(input: [
      { "role" => "user", "content" => [{ "type" => "input_text", "text" => "!mock -- what" }] },
      { "type" => "function_call", "call_id" => "c1", "name" => "bash", "arguments" => "{}" },
      { "type" => "function_call_output", "call_id" => "c1", "output" => "THE TOOL RESULT" },
    ])

    text = events.filter_map { PARSER.send(:output_text_delta, _1) }.join
    assert_includes text, "THE TOOL RESULT",
      "the fake echoes its input; a result it cannot read is a result no journey can assert on"
  end

  # THE SCRIPT ADVANCES WITH THE ANSWERS, and ends. The directive lives in
  # the user message and that message rides every round, so the fake reads
  # WHICH round it is from the input itself — the count of tool results
  # already present is the index. Past the end it speaks, which is what
  # lets a loop complete at all.
  #
  # Without a sequence, one round was the ceiling: enough to prove a tool
  # round, not enough to prove an AGENT — nothing could show a model
  # reading a result and deciding what to do next, which is the behaviour
  # every long-session feature exists to serve.
  def test_the_scripted_sequence_advances_with_each_answer_and_then_ends
    script = "!mock tool_call=read,bash -- go"
    round = lambda do |answers|
      items = [{ "role" => "user",
                 "content" => [{ "type" => "input_text", "text" => script }] }]
      answers.times do |n|
        items << { "type" => "function_call", "call_id" => "c#{n}",
                   "name" => "x", "arguments" => "{}" }
        items << { "type" => "function_call_output", "call_id" => "c#{n}",
                   "output" => "result #{n}" }
      end
      stream(input: items, tools: TOOLS)
    end

    called = lambda do |events|
      body = events.filter_map { PARSER.send(:terminal_response_body_from_event, _1) }.first
      item = body.fetch("output").first
      item.fetch("type") == "function_call" ? item.fetch("name") : nil
    end

    assert_equal "read", called.call(round.call(0)), "round one opens the script"
    assert_equal "bash", called.call(round.call(1)), "round two reads the answer and moves on"
    assert_nil called.call(round.call(2)), "past the end it speaks, and the loop can complete"
    assert_includes round.call(2).filter_map { PARSER.send(:output_text_delta, _1) }.join,
      "result 1", "and what it says is what it was told"
  end

  private

    def stream(model: "mock-text", input:, tools: nil, **fields)
      _, _, body = @app.call(
        "REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/responses",
        "CONTENT_TYPE" => "application/json",
        "rack.input" => StringIO.new(JSON.generate({ model: model, input: input, tools: tools }.compact.merge(fields)))
      )

      body.to_a.join.split("\n\n").filter_map do |frame|
        data = frame.sub(/\Adata: /, "").strip
        next if data.empty? || data == "[DONE]"

        JSON.parse(data)
      end
    end
end
