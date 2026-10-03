require "test_helper"

# THE LOWERED PREFIX ACROSS TURNS on the one wire that binds thinking to it. The sealed entries of a
# later turn extending the earlier request is the kernel's claim; this pins what the Anthropic
# lowering makes of it — the `system` field and the `tools` byte-equal across turns, and the earlier
# request's messages a block-for-block prefix of the next turn's, its signed thinking included — so
# an edit the entry list cannot show (a system entry hoisted out of history, a block folded or
# dropped in lowering) fails here.
class Conversations::ContextAssemblyAnthropicPrefixTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

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
    run_loop_round!(loop1, anthropic_response([
      { "type" => "thinking", "thinking" => "plan one", "signature" => "sig-one" },
      { "type" => "tool_use", "id" => "call_a", "name" => "read_file", "input" => { "path" => "a" } },
    ], stop_reason: "tool_use"))
    settled = AgentLoops::Parks::Settle.call(node: loop1.agent_loop_nodes.find_by!(tool_call_id: "call_a"),
      trusted: true, content: "contents of a", outcome: "completed")
    assert_predicate settled, :applied?
    schedule_loop!(loop1)
    answering = loop_attempt(loop1)
    last = wire(answering)
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
    assert_equal %w[sig-one sig-two], signatures(second), "every round's thinking rides the next turn"
    assert_equal ["and next"], second.fetch("messages").last.fetch("content").map { |block| block["text"] },
      "the window already carries this identical lead in turn 1's preface: the turn lays its words alone"
  end

  private

    def turn!(text)
      post_input!(@conversation, acting_user: @agent, kind: "direct_reply", text: text,
        provider_id: "anthropic", model_ref: MODEL,
        context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => LEAD }] })
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.conversation_turns.order(:position).last
      agent_loop = turn.active_variant.agent_loop
      schedule_loop!(agent_loop)
      [turn, agent_loop]
    end

    def apply_answer!(agent_loop, attempt, content)
      apply_via(attempt, anthropic_response(content, stop_reason: "end_turn"))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_loop)
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
