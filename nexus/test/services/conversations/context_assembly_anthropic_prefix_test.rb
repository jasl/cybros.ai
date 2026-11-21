require "test_helper"

# THE LOWERED PREFIX ACROSS TURNS on the one wire that binds thinking to it. The sealed entries of a
# later turn extending the earlier request is the kernel's claim; this pins what the Anthropic
# lowering makes of it — the `system` field and the `tools` byte-equal across turns, and the earlier
# request's messages a block-for-block prefix of the next turn's, its signed thinking included — so
# an edit the entry list cannot show (a system entry hoisted out of history, a block folded or
# dropped in lowering) fails here.
class Conversations::ContextAssemblyAnthropicPrefixTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  MODEL = "claude-opus-5-5".freeze
  LEAD = "Relative paths resolve against /w.".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "anthropic", api_key: "test-only-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "anthropic", expected_lock_version: nil)
    written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt", content: "I am the agent.")
    assert_equal :written, written.outcome
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "a later turn's lowered request keeps system and tools and extends the earlier messages, thinking included" do
    turn1, loop1 = turn!("read the notes")
    tool_turn = [
      { "type" => "thinking", "thinking" => "", "signature" => "sig-one" },
      { "type" => "text", "text" => "Reading a." },
      { "type" => "tool_use", "id" => "call_a", "name" => "read_file", "input" => { "path" => "a" } },
      { "type" => "thinking", "thinking" => "Also check b.", "signature" => "sig-progress" },
      { "type" => "text", "text" => "Reading b." },
      { "type" => "tool_use", "id" => "call_b", "name" => "read_file", "input" => { "path" => "b" } },
    ]
    run_loop_round!(loop1, anthropic_response(tool_turn, stop_reason: "tool_use"))
    %w[a b].each do |path|
      settled = Runs::Parks::Settle.call(node: loop1.tasks.find_by!(tool_call_id: "call_#{path}"),
        trusted: true, content: "contents of #{path}", outcome: "completed")
      assert_predicate settled, :applied?
    end
    schedule_loop!(loop1)
    answering = loop_attempt(loop1)
    last = wire(answering)
    assert_equal tool_turn, last.fetch("messages").find { |message| message["role"] == "assistant" }.fetch("content")
    results = last.fetch("messages").last.fetch("content")
    assert_equal %w[call_a call_b], results.map { |block| block.fetch("tool_use_id") }
    assert_equal({ "type" => "ephemeral", "ttl" => "1h" }, results.last.fetch("cache_control"))
    apply_answer!(loop1, answering, [
      { "type" => "thinking", "thinking" => "plan two", "signature" => "sig-two" },
      { "type" => "text", "text" => "the notes, read" },
    ])
    assert_equal "completed", turn1.reload.status

    _turn2, loop2 = turn!("and next")
    second = wire(loop_attempt(loop2))

    assert_equal last.fetch("system"), second.fetch("system"), "the system field is byte-equal across turns"
    assert_equal last.fetch("tools"), second.fetch("tools")
    earlier = blocks(last.fetch("messages"))
    assert_equal earlier, blocks(second.fetch("messages")).first(earlier.length),
      "the earlier request's messages, block for block, its lead and its signed thinking included"
    assert_equal %w[sig-one sig-progress sig-two], signatures(second), "every round's thinking rides the next turn"
    assert_equal ["and next"], second.fetch("messages").last.fetch("content").map { |block| block["text"] },
      "the window already carries this identical lead in turn 1's preface: the turn lays its words alone"
  end

  test "a loop fallback keeps the admitted foreign seed and a new turn can restore the producer's history" do
    fable = "claude-fable-5-2"
    declare_tools!(@agent, fallback_models: ["anthropic/#{fable}"])
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "test-only-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "openai_api", expected_lock_version: nil)

    _turn, first = turn!("Choose a route.", model: fable)
    apply_answer!(first, loop_attempt(first), [
      { "type" => "thinking", "thinking" => "Take the coastal route.", "signature" => "fable-original" },
      { "type" => "redacted_thinking", "data" => "fable-opaque" },
      { "type" => "text", "text" => "Route chosen." },
    ])

    _turn, second = turn!("Review it.", provider: "openai_api", model: "gpt-6.2-sol")
    review = loop_attempt(second)
    foreign = wire(review)
    apply_via(review, sse_refused("Refused."))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(second)
    fallback = loop_attempt(second)
    retried = wire(fallback)
    assert_equal fable, retried.fetch("model")
    [foreign, retried].each do |request|
      assert_includes request.to_json, "Take the coastal route."
      assert_includes request.to_json, "Route chosen."
      assert_not_includes request.to_json, "fable-original"
      assert_not_includes request.to_json, "fable-opaque"
    end

    apply_answer!(second, fallback, [{ "type" => "text", "text" => "Reviewed." }])
    _turn, third = turn!("Confirm.", model: fable)
    restored = wire(loop_attempt(third))
    assert_includes signatures(restored), "fable-original"
    assert_includes restored.to_json, "fable-opaque"
  end

  private

    def turn!(text, provider: "anthropic", model: MODEL)
      post_input!(@conversation, acting_user: @agent, kind: "direct_reply", text: text,
        provider_id: provider, model_ref: model,
        context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => LEAD }] })
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.turns.order(:position).last
      run = turn.active_variant.run
      schedule_loop!(run)
      [turn, run]
    end

    def apply_answer!(run, attempt, content)
      apply_via(attempt, anthropic_response(content, stop_reason: "end_turn"))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(run)
      Conversations::Turns::Converge.call
    end

    def wire(attempt)
      built = build(attempt)
      assert_predicate built, :built?, built.refusal.inspect
      JSON.parse(built.request.payload)
    end

    # The Messages API's complete JSON response is also legal on the streaming transport.
    def anthropic_response(content, stop_reason:)
      json_response(200, {
        "id" => "msg_prefix", "type" => "message", "role" => "assistant",
        "content" => content, "stop_reason" => stop_reason,
        "usage" => { "input_tokens" => 2, "output_tokens" => 3 },
      })
    end

    # Each message's blocks with the cache markers off: the rolling tail marker moves every request
    # and sits outside the prefix a cache lookup and the thinking binding compare.
    def blocks(messages)
      messages.map do |message|
        [message.fetch("role"), message.fetch("content").map { |block| block.except("cache_control") }]
      end
    end

    def signatures(payload)
      payload.fetch("messages").flat_map { |message| message.fetch("content") }
        .filter_map { |block| block["signature"] if block["type"] == "thinking" }
    end
end
