require "test_helper"

class Conversations::GeminiHistoryReplayTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  SIGNATURE = "history-tool-signature".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "gemini", api_key: "test-only-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "gemini", expected_lock_version: nil)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "all replay preserves a tool signature when the next turn rebuilds history" do
    complete_tool_turn

    _next_turn, next_loop = reply("Explain what you read")
    parts = wire_parts(loop_attempt(next_loop))
    assert_tool_pair(parts)
    assert_equal [SIGNATURE], parts.filter_map { |part| part["thoughtSignature"] },
      "the same-model history must preserve the native payload selected for replay"
  end

  test "a signature without readable thought survives all replay" do
    complete_tool_turn(thought: false)

    _next_turn, next_loop = reply("Explain what you read")
    parts = wire_parts(loop_attempt(next_loop))
    assert_tool_pair(parts)
    assert_equal [SIGNATURE], parts.filter_map { |part| part["thoughtSignature"] }
    assert_empty parts.select { |part| part["thought"] }
  end

  test "none replay retains the tool pair without the native signature" do
    complete_tool_turn

    _next_turn, next_loop = reply("Explain what you read", replay: "none")
    parts = wire_parts(loop_attempt(next_loop))
    assert_tool_pair(parts)
    assert_empty parts.filter_map { |part| part["thoughtSignature"] }
    assert_empty parts.select { |part| part["thought"] }
  end

  private

    def complete_tool_turn(thought: true)
      turn, agent_run = reply("Read the file")
      parts = thought ? [{ "thought" => true, "text" => "Read before answering." }] : []
      run_loop_round!(agent_run, response(parts + [
        { "thoughtSignature" => SIGNATURE,
          "functionCall" => { "id" => "read-call", "name" => "read_file", "args" => { "path" => "file" } } },
      ]))
      tool = agent_run.agent_run_tasks.find_by!(tool_call_id: "read-call")
      assert_equal "dispatched", tool.status
      settled = AgentRuns::Parks::Settle.call(node: tool, trusted: true,
        content: "file contents", outcome: "completed")
      assert_predicate settled, :applied?
      schedule_loop!(agent_run)
      continuation = loop_attempt(agent_run)
      assert_equal [SIGNATURE], wire_parts(continuation).filter_map { |part| part["thoughtSignature"] }
      apply_via(continuation, response([{ "text" => "The file has been read." }]))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
    end

    def assert_tool_pair(parts)
      assert_equal ["read-call"], parts.filter_map { |part| part.dig("functionCall", "id") }
      assert_equal ["read-call"], parts.filter_map { |part| part.dig("functionResponse", "id") }
    end

    def reply(text, replay: "all")
      turn, agent_run = materialize_loop_reply!(@conversation.reload, agent: @agent, text: text,
        provider_id: "gemini", model_ref: "gemini-3.8-flash",
        context_options: { "reasoning_replay" => { "mode" => replay } })
      schedule_loop!(agent_run)
      [turn, agent_run]
    end

    def wire_parts(attempt)
      built = build(attempt)
      assert_predicate built, :built?, built.refusal.inspect
      JSON.parse(built.request.payload).fetch("contents").flat_map { |message| message.fetch("parts") }
    end

    def response(parts)
      payload = {
        "responseId" => "gemini-history-response",
        "candidates" => [{ "content" => { "role" => "model", "parts" => parts }, "finishReason" => "STOP" }],
        "usageMetadata" => { "promptTokenCount" => 2, "candidatesTokenCount" => 3,
                             "thoughtsTokenCount" => 5, "totalTokenCount" => 10 },
      }
      { status: 200, headers: { "content-type" => "text/event-stream" },
        sse: ["data: #{JSON.generate(payload)}\n\n"] }
    end
end
