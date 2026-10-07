require "test_helper"

class AgentRuns::NativeReasoningModelSwitchTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  PLAN = "Read the file before deciding which change to make.".freeze
  ENCRYPTED = "origin-model-encrypted-reasoning".freeze
  SIGNATURE = "origin-model-thinking-signature".freeze
  REDACTED = "origin-model-redacted-thinking".freeze
  CALL_ID = "call_read".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
  end

  # A trace another model produced contributes nothing on the next model's
  # wire: no blob, and no fence standing in for it — the vendors drop what
  # a model cannot read rather than render it as words.
  test "Responses encrypted reasoning in a sealed continuation carries nothing across a model switch" do
    enable_lane("openai_api")
    first = sse_success("Reading the file.", reasoning: PLAN, reasoning_encrypted: ENCRYPTED,
      tool_calls: [{ id: CALL_ID, name: "read_file", arguments: '{"path":"file"}' }])
    same, crossed = switch_wires(origin: "openai_api/gpt-6.1-sol", target: "openai_api/gpt-6-luna",
      first: first, final: sse_success("The file has been read."))

    same_items = same.fetch("input")
    assert_equal [ENCRYPTED], same_items.filter_map { |item| item["encrypted_content"] },
      "the same-model tool continuation must first seal and replay the original encrypted item"
    assert_responses_pair(same_items)

    crossed_items = crossed.fetch("input")
    assert_responses_pair(crossed_items)
    assert_empty crossed_items.filter_map { |item| item["encrypted_content"] },
      "a later authored model must not inherit another model's encrypted reasoning from the sealed prefix"
    text = crossed_items.flat_map { |item| item.fetch("content", []) }.filter_map { |part| part["text"] }.join("\n")
    assert_not_includes text, PLAN, "no summary crosses as words"
    assert_includes text, "The file has been read."
  end

  # The Responses wire labels the message it produced (`phase`) and asks
  # for the label back: the continuation resends it where the model said
  # it — after the thought that produced it, before the call it
  # introduced — and a later model on the SAME lane inherits it with the
  # sealed prefix, while the other model's encrypted thought does not.
  test "the same-lane continuation resends the assistant phase, and a model switch on the lane keeps it" do
    enable_lane("openai_api")
    first = sse_success("Reading the file.", phase: "commentary", reasoning: PLAN, reasoning_encrypted: ENCRYPTED,
      tool_calls: [{ id: CALL_ID, name: "read_file", arguments: '{"path":"file"}' }])
    same, crossed = switch_wires(origin: "openai_api/gpt-6.1-sol", target: "openai_api/gpt-6-luna",
      first: first, final: sse_success("The file has been read."))

    items = same.fetch("input")
    said = items.index { |item| item_text(item).include?("Mock: Reading the file.") }
    assert_equal "commentary", items[said]["phase"]
    assert_operator items.index { |item| item["encrypted_content"] == ENCRYPTED }, :<, said
    assert_operator said, :<, items.index { |item| item["type"] == "function_call" }

    crossed_items = crossed.fetch("input")
    said = crossed_items.find { |item| item_text(item).include?("Mock: Reading the file.") }
    assert_equal "commentary", said["phase"], "a later model on the lane keeps the label"
    assert_empty crossed_items.filter_map { |item| item["encrypted_content"] }
  end

  # A round that thought between its calls: each blob replays before the
  # item it produced, never gathered ahead of the message; after a switch
  # neither rides, and the round's own items keep their order.
  test "a round that thought between two calls replays both blobs, each before its call" do
    enable_lane("openai_api")
    first = responses_output([
      { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "E1",
        "summary" => [{ "type" => "summary_text", "text" => "plan one" }] },
      { "type" => "message", "id" => "msg_1", "role" => "assistant", "phase" => "commentary",
        "content" => [{ "type" => "output_text", "text" => "Reading both." }] },
      { "type" => "function_call", "id" => "fc_a", "call_id" => "call_a", "name" => "read_file",
        "arguments" => '{"path":"a"}' },
      { "type" => "reasoning", "id" => "rs_2", "encrypted_content" => "E2",
        "summary" => [{ "type" => "summary_text", "text" => "plan two" }] },
      { "type" => "function_call", "id" => "fc_b", "call_id" => "call_b", "name" => "read_file",
        "arguments" => '{"path":"b"}' },
    ])
    same, crossed = switch_wires(origin: "openai_api/gpt-6.1-sol", target: "openai_api/gpt-6-luna",
      first: first, final: sse_success("Both read."), settle: %w[r1t0 r1t1])

    items = same.fetch("input")
    assert_equal %w[E1 E2], items.filter_map { |item| item["encrypted_content"] }
    order = [
      items.index { |item| item["encrypted_content"] == "E1" },
      items.index { |item| item_text(item) == "Reading both." },
      items.index { |item| item["call_id"] == "call_a" && item["type"] == "function_call" },
      items.index { |item| item["encrypted_content"] == "E2" },
      items.index { |item| item["call_id"] == "call_b" && item["type"] == "function_call" },
      items.index { |item| item["type"] == "function_call_output" },
    ]
    assert_equal order.sort, order, "every thought before the item it produced; the results after every call"

    crossed_items = crossed.fetch("input")
    assert_empty crossed_items.filter_map { |item| item["encrypted_content"] }
    assert_not_includes crossed.to_json, "plan one"
    assert_not_includes crossed.to_json, "plan two"
    order = [
      crossed_items.index { |item| item_text(item) == "Reading both." },
      crossed_items.index { |item| item["call_id"] == "call_a" && item["type"] == "function_call" },
      crossed_items.index { |item| item["call_id"] == "call_b" && item["type"] == "function_call" },
    ]
    assert_equal order.sort, order, "the round's own items keep their places: #{order.inspect}"
    assert_equal "commentary", crossed_items.find { |item| item_text(item) == "Reading both." }["phase"]
  end

  # Anthropic's own rule for a switch between its models: keep sending the
  # full history and let the API drop what the current model cannot read.
  # The sealed prefix passes every block to the next Anthropic model
  # unchanged — signed, signature-only and redacted alike — and invents no text.
  test "Anthropic signed and redacted thinking passes unchanged to another Anthropic model" do
    same, crossed = anthropic_switch(thinking: PLAN)

    assert_anthropic_native(same, thinking: PLAN)
    assert_anthropic_native(crossed, thinking: PLAN)
    assert_includes anthropic_blocks(crossed).filter_map { |part| part["text"] }.join("\n"), "The file has been read."
  end

  test "Anthropic signature-only thinking passes unchanged to another Anthropic model without inventing text" do
    same, crossed = anthropic_switch(thinking: "")

    assert_anthropic_native(same, thinking: "")
    assert_anthropic_native(crossed, thinking: "")
    assert_not_includes crossed.to_json, "<think>"
  end

  # A REFUSAL'S SWITCH REPLAYS LIKE ANY MODEL SWITCH: the refused round
  # stored no body, so its requeued execution composes against the
  # fallback's selection from the rounds before it — a foreign signature
  # carries nothing across, and each call pairs with its result under the
  # new wire.
  test "a round refused on the Anthropic lane re-runs on the declared Responses fallback with its calls paired" do
    enable_lane("anthropic")
    enable_lane("openai_api")
    first = anthropic_response([
      { "type" => "thinking", "thinking" => PLAN, "signature" => SIGNATURE },
      { "type" => "tool_use", "id" => CALL_ID, "name" => "read_file", "input" => { "path" => "file" } },
    ], stop_reason: "tool_use")
    refused = json_response(200, {
      "id" => "refused-response", "type" => "message", "role" => "assistant", "content" => [],
      "stop_reason" => "refusal", "stop_details" => { "category" => "cyber", "explanation" => "No." },
      "usage" => { "input_tokens" => 2, "output_tokens" => 0 },
    })

    crossed = refusal_wire(origin: "anthropic/claude-opus-5-5", fallback: "openai_api/gpt-6-luna",
      first: first, refused: refused)

    items = crossed.fetch("input")
    assert_responses_pair(items)
    assert_not_includes crossed.to_json, SIGNATURE, "a foreign signature never rides the fallback's wire"
    assert_not_includes crossed.to_json, PLAN, "nor its thinking as words"
  end

  test "a round refused on the Responses lane re-runs on the declared Anthropic fallback with its calls paired" do
    enable_lane("openai_api")
    enable_lane("anthropic")
    first = sse_success("Reading the file.", reasoning: PLAN, reasoning_encrypted: ENCRYPTED,
      tool_calls: [{ id: CALL_ID, name: "read_file", arguments: '{"path":"file"}' }])

    crossed = refusal_wire(origin: "openai_api/gpt-6.1-sol", fallback: "anthropic/claude-opus-5-5",
      first: first, refused: sse_refused("I can't help with that."))

    blocks = anthropic_blocks(crossed)
    assert_anthropic_pair(blocks)
    assert_not_includes crossed.to_json, ENCRYPTED, "another model's encrypted thought never rides the fallback's wire"
    assert_empty blocks.select { |part| %w[thinking redacted_thinking].include?(part["type"]) }
  end

  private

    def enable_lane(provider_id)
      ModelProviders::SetAPIKey.call(account: @account, provider_id: provider_id, api_key: "test-only-key")
      ModelProviders::EnableLane.call(account: @account, provider_id: provider_id, expected_lock_version: nil)
    end

    def selection(model_ref) = { "model" => model_ref, "reasoning_effort" => "low" }

    def switch_wires(origin:, target:, first:, final:, settle: %w[r1t0])
      agent_run = seed(
        model("read", "model" => selection(origin), "prompt" => "Read the file", "tools" => [READ_TOOL]),
        model("review", "model" => selection(target), "prompt" => "Review the findings", "tools" => [READ_TOOL])
      )
      AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, first)

      settle.each do |key|
        tool = loop_node(agent_run, key)
        assert_equal "dispatched", tool.status
        settled = AgentRuns::Parks::Settle.call(node: tool, trusted: true,
          content: "the file contents", outcome: "completed")
        assert_predicate settled, :applied?
      end
      schedule_loop!(agent_run)

      continuation = loop_attempt(agent_run)
      assert_equal loop_node(agent_run, "r1").selected_model_invocation_id, continuation.model_invocation.id
      same = wire(continuation)
      prefix = sealed_request_entries(continuation.model_invocation)
      apply_via(continuation, final)
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)

      review = loop_node(agent_run, "review")
      assert_includes review.input_from_node_keys, "r1",
        "ordinary authoring splices the next model after the completed tool continuation"
      attempt = loop_attempt(agent_run)
      assert_equal target, "#{attempt.model_invocation.provider_id}/#{attempt.model_invocation.model_ref}"
      crossed = wire(attempt)
      assert_equal prefix, sealed_request_entries(continuation.model_invocation.reload),
        "lowering for a different model must not rewrite the source's sealed request"
      [same, crossed]
    end

    # The step `read` runs on `origin` and calls a tool; its continuation
    # `r1` is refused, and the answering agent's declared `fallback`
    # re-runs it. Answers the fallback's wire for that re-run.
    def refusal_wire(origin:, fallback:, first:, refused:)
      agent = users(:agent)
      declare_tools!(agent, tools: [READ_TOOL], fallback_model: fallback)
      agent_run = seed(
        model("read", "model" => selection(origin), "prompt" => "Read the file", "tools" => [READ_TOOL]),
        creating_user: agent
      )
      AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, first)
      settled = AgentRuns::Parks::Settle.call(node: loop_node(agent_run, "r1t0"), trusted: true,
        content: "the file contents", outcome: "completed")
      assert_predicate settled, :applied?
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, refused)

      continuation = loop_node(agent_run, "r1")
      assert_equal [1, fallback], [continuation.execution_generation,
                                   "#{continuation.provider_id}/#{continuation.model_ref}"]
      attempt = loop_attempt(agent_run)
      assert_equal fallback, "#{attempt.model_invocation.provider_id}/#{attempt.model_invocation.model_ref}"
      wire(attempt)
    end

    def wire(attempt)
      built = build(attempt)
      assert_predicate built, :built?, built.refusal.inspect
      JSON.parse(built.request.payload)
    end

    # An input item's words: a message's text parts, joined.
    def item_text(item) = Array(item["content"]).filter_map { |part| part["text"] }.join

    def assert_responses_pair(items)
      assert_equal [CALL_ID], items.select { |item| item["type"] == "function_call" }.map { |item| item["call_id"] }
      assert_equal [CALL_ID], items.select { |item| item["type"] == "function_call_output" }.map { |item| item["call_id"] }
    end

    def anthropic_switch(thinking:)
      enable_lane("anthropic")
      first = anthropic_response([
        { "type" => "thinking", "thinking" => thinking, "signature" => SIGNATURE },
        { "type" => "redacted_thinking", "data" => REDACTED },
        { "type" => "tool_use", "id" => CALL_ID, "name" => "read_file", "input" => { "path" => "file" } },
      ], stop_reason: "tool_use")
      final = anthropic_response([{ "type" => "text", "text" => "The file has been read." }], stop_reason: "end_turn")
      switch_wires(origin: "anthropic/claude-opus-5-5", target: "anthropic/claude-sonnet-5", first: first, final: final)
    end

    # The Messages API's complete JSON response is also legal on the streaming
    # transport; the existing protocol fixture pins this native block shape.
    def anthropic_response(content, stop_reason:)
      json_response(200, {
        "id" => "native-reasoning-response", "type" => "message", "role" => "assistant",
        "content" => content, "stop_reason" => stop_reason,
        "usage" => { "input_tokens" => 2, "output_tokens" => 3 },
      })
    end

    def anthropic_blocks(wire) = wire.fetch("messages").flat_map { |message| message.fetch("content") }

    def assert_anthropic_native(wire, thinking:)
      blocks = anthropic_blocks(wire)
      assert_equal [{ "type" => "thinking", "thinking" => thinking, "signature" => SIGNATURE }],
        blocks.select { |part| part["type"] == "thinking" }
      assert_equal [{ "type" => "redacted_thinking", "data" => REDACTED }],
        blocks.select { |part| part["type"] == "redacted_thinking" }
      assert_anthropic_pair(blocks)
    end

    def assert_anthropic_pair(blocks)
      assert_equal [CALL_ID], blocks.select { |part| part["type"] == "tool_use" }.map { |part| part["id"] }
      assert_equal [CALL_ID], blocks.select { |part| part["type"] == "tool_result" }.map { |part| part["tool_use_id"] }
    end
end
