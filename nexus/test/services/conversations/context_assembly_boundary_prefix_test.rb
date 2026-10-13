require "test_helper"

# THE BOUNDARY PROPERTY, byte for byte, where every provider's cache keys it: turn N+1's first
# request begins with turn N's LAST request — on the kernel's sealed entries AND on the body the
# wire is lowered to, since the lowerings fold items by position (a chat wire folds a round's calls
# into one assistant message) — then turn N's answer with the reasoning its request would replay,
# then turn N+1's own words. One case per reasoning field the kernel replays in: the Responses
# items (the dev lane), the chat message's `reasoning_details` (the broker's Kimi row), DeepSeek's
# plain-text reasoning item; and the loop lane keeps its own turn's reasoning after the kill switch
# stamped the conversation (the switch is read where seeds are made).
class Conversations::ContextAssemblyBoundaryPrefixTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def converge! = Conversations::Turns::Converge.call

  test "the Responses items: every turn's first request extends the last, entries and lowered input alike" do
    first_turn!("dev", "mock-text", "read a") do |agent_run|
      run_loop_round!(agent_run, sse_success("calling", reasoning: "plan a", reasoning_encrypted: "blob-a",
        tool_calls: [{ id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" }]))
      settle!(agent_run, "call_a")
      run_loop_round!(agent_run, sse_success("read", reasoning: "plan b", reasoning_encrypted: "blob-b"))
    end
    second = next_turn!("dev", "mock-text", "and next") do |agent_run|
      run_loop_round!(agent_run, sse_success("next", reasoning: "plan c", reasoning_encrypted: "blob-c"))
    end
    third = next_turn!("dev", "mock-text", "and last")

    assert_extends @turns.fetch(0), second, "input"
    assert_extends @turns.fetch(1), third, "input"
    assert_equal %w[blob-a blob-b blob-c], lowered(third).fetch("input").filter_map { |item| item["encrypted_content"] },
      "every turn's reasoning, in the order it was thought"
  end

  test "the chat field: a calling round's reasoning details ride its one assistant message on every later turn" do
    enable_lane("openrouter")
    kimi = "moonshotai/kimi-k3"
    first_turn!("openrouter", kimi, "read a") do |agent_run|
      apply_via(loop_attempt(agent_run), chat_stream(reasoning: "look at a",
        tool_calls: [{ "id" => "call_a", "name" => "read_file", "arguments" => "{\"path\":\"a\"}" }]))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
      settle!(agent_run, "call_a")
      apply_via(loop_attempt(agent_run), chat_stream(reasoning: "a is read", content: "a says hi"))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
    end
    second = next_turn!("openrouter", kimi, "and next")

    assert_extends @turns.fetch(0), second, "messages"
    messages = lowered(second).fetch("messages")
    calling = messages.find { |message| message["tool_calls"] }
    assert_equal ["look at a"], calling.fetch("reasoning_details").map { |block| block["text"] },
      "the calling round's own blocks, verbatim, on the message that carries its call"
    assert_equal ["a is read"], messages.filter_map { |message| message["reasoning_details"] }.drop(1).flatten
      .map { |block| block["text"] }, "and the answer's on its own message"
    assert_not_includes second.to_json, "<think>"
  end

  test "DeepSeek's plain-text items: each thought replays at its place on every later turn" do
    enable_lane("deepseek")
    first_turn!("deepseek", "deepseek-flash", "read a") do |agent_run|
      apply_via(loop_attempt(agent_run), responses_output([
        { "type" => "reasoning", "id" => "rs_1", "content" => [{ "type" => "reasoning_text", "text" => "look at a" }] },
        { "type" => "function_call", "id" => "fc_1", "call_id" => "call_a", "name" => "read_file",
          "arguments" => "{\"path\":\"a\"}" },
      ]))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
      settle!(agent_run, "call_a")
      apply_via(loop_attempt(agent_run), responses_output([
        { "type" => "reasoning", "id" => "rs_2", "content" => [{ "type" => "reasoning_text", "text" => "a is read" }] },
        { "type" => "message", "role" => "assistant", "content" => [{ "type" => "output_text", "text" => "a says hi" }] },
      ]))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
    end
    second = next_turn!("deepseek", "deepseek-flash", "and next")

    assert_extends @turns.fetch(0), second, "input"
    items = lowered(second).fetch("input")
    reasoning = items.each_index.select { |index| items[index]["type"] == "reasoning" }
    assert_equal ["look at a", "a is read"], reasoning.map { |index| items[index].dig("content", 0, "text") }
    assert_operator reasoning.first, :<, items.index { |item| item["type"] == "function_call" },
      "the thought rides before the call it produced"
  end

  # The kill switch is read where a turn's request is compiled: a turn that already runs keeps
  # replaying its own reasoning (a tool turn must pass it back), and only the next seed omits it.
  test "after the kill switch stamps, the running turn's rounds still carry its own reasoning" do
    _turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "read a")
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("calling", reasoning: "plan a", reasoning_encrypted: "blob-a",
      tool_calls: [{ id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" }]))
    @conversation.reload.downgrade_reasoning_replay(turn: agent_run.conversation_turn)
    assert_not_nil @conversation.reload.reasoning_replay_downgraded_at
    settle!(agent_run, "call_a")

    assert_equal ["blob-a"], round_request_entries(loop_node(agent_run, "r2"))
      .filter_map { |payload| payload.dig("payload", "encrypted_content") }
  end

  private

    def enable_lane(provider_id)
      ModelProviders::SetAPIKey.call(account: @account, provider_id: provider_id, api_key: "test-only-key")
      ModelProviders::EnableLane.call(account: @account, provider_id: provider_id, expected_lock_version: nil)
    end

    # A reply turn on `model_ref`, its rounds driven by the block; the turn's LAST round's
    # invocation is what the next turn must extend.
    def first_turn!(provider_id, model_ref, text)
      @turns = []
      next_turn!(provider_id, model_ref, text) { |agent_run| yield agent_run }
    end

    def next_turn!(provider_id, model_ref, text)
      post_input!(@conversation, acting_user: @agent, kind: "direct_reply", text: text,
        provider_id: provider_id, model_ref: model_ref)
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      agent_run = @conversation.conversation_turns.order(:position).last.active_variant.agent_run
      schedule_loop!(agent_run)
      first = loop_node(agent_run, "r1").selected_model_invocation
      if block_given?
        yield agent_run
        converge!
        assert_equal "completed", agent_run.reload.status
        @turns << last_round_invocation(agent_run)
      end
      first
    end

    def last_round_invocation(agent_run)
      ModelInvocation.find(agent_run.agent_run_tasks.where(type: "AgentRunTasks::ModelTask")
        .where.not(selected_model_invocation_id: nil).order(:id).last.selected_model_invocation_id)
    end

    def settle!(agent_run, call_id)
      settled = AgentRuns::Parks::Settle.call(node: agent_run.agent_run_tasks.find_by!(tool_call_id: call_id),
        trusted: true, content: "contents of #{call_id}", outcome: "completed")
      assert_predicate settled, :applied?
      schedule_loop!(agent_run)
    end

    # The earlier turn's last request, whole, leads the later turn's first: its sealed entries,
    # and the list its body lowers to on the wire (`input` on the Responses wires, `messages` on chat).
    def assert_extends(earlier, later, list)
      before = sealed_request_entries(earlier)
      assert_equal before.map { |entry| Nexus::CanonicalJson.encode(entry) },
        sealed_request_entries(later).first(before.length).map { |entry| Nexus::CanonicalJson.encode(entry) },
        "the kernel entries extend"
      wire = lowered(earlier).fetch(list)
      assert_equal wire, lowered(later).fetch(list).first(wire.length), "the lowered #{list} extend"
    end

    def lowered(invocation)
      built = ModelRequests::Build.call(invocation: invocation, profile: DevModelLane.profile_for_invocation(invocation),
        base_url: ModelCatalog.provider_base_url(invocation.provider_id), host: "solid_queue")
      assert_predicate built, :built?, built.refusal.inspect
      JSON.parse(built.request.payload)
    end

    # The broker's chat stream: the reasoning delta with its detail block, the calls or the
    # words, then the finish with the usage.
    def chat_stream(reasoning:, content: nil, tool_calls: [])
      detail = { "type" => "reasoning.text", "text" => reasoning, "format" => "moonshot", "index" => 0 }
      delta = { "role" => "assistant", "reasoning" => reasoning, "reasoning_details" => [detail] }
      chunks = [{ "id" => "gen", "choices" => [{ "index" => 0, "delta" => delta }] }]
      chunks << { "id" => "gen", "choices" => [{ "index" => 0, "delta" => { "content" => content } }] } if content
      if tool_calls.any?
        calls = tool_calls.each_with_index.map do |call, index|
          { "index" => index, "id" => call.fetch("id"), "type" => "function",
            "function" => { "name" => call.fetch("name"), "arguments" => call.fetch("arguments") } }
        end
        chunks << { "id" => "gen", "choices" => [{ "index" => 0, "delta" => { "tool_calls" => calls } }] }
      end
      chunks << { "id" => "gen", "choices" => [{ "index" => 0, "delta" => {},
                                                 "finish_reason" => tool_calls.any? ? "tool_calls" : "stop" }],
                  "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15,
                               "completion_tokens_details" => { "reasoning_tokens" => 3 } } }
      { sse: chunks.map { |chunk| "data: #{JSON.generate(chunk)}\n\n" } + ["data: [DONE]\n\n"],
        status: 200, headers: { "content-type" => "text/event-stream" } }
    end
end
