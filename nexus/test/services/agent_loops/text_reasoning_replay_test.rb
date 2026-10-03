require "test_helper"
require_relative "../../test_helpers/compaction_summary_test_helper"

class AgentLoops::TextReasoningReplayTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper
  include CompactionSummaryTestHelper

  REASONING = "Read the marker before deciding which change to make.".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "deepseek", api_key: "test-only-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "deepseek", expected_lock_version: nil)
  end

  # DeepSeek's Responses route with tools requires every earlier turn's
  # reasoning back, in its own field: a tool-only round's continuation
  # replays the plain-text reasoning item before the call it produced —
  # never a fence in an assistant message, never an empty answer.
  test "a tool-only response carries its captured text reasoning into the continuation as the wire's item" do
    agent_loop = seed(model("ask", "model" => { "model" => "deepseek/deepseek-flash", "reasoning_effort" => "high" },
      "prompt" => "Read the marker", "tools" => [LoopLaneTestHelper::READ_TOOL]))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, tool_only_response)

    source = loop_node(agent_loop, "ask")
    assert_equal "completed", source.status
    assert_empty source.output_body&.effective_text.to_s
    trace = ModelReasoning::Trace.new(
      envelope: source.invocation_body("reasoning_trace").content_body_entries.sole.content_fragment.payload
    )
    assert_equal "responses_reasoning_text", trace.origin_format_variant
    assert_equal [REASONING], trace.reasoning_items.filter_map { |item| item["text"] },
      "the real provider response captured its reasoning despite having no ordinary answer"

    settled = AgentLoops::Parks::Settle.call(node: loop_node(agent_loop, "r1t0"), trusted: true,
      content: "marker contents", outcome: "completed")
    assert_predicate settled, :applied?
    schedule_loop!(agent_loop)

    built = build(loop_attempt(agent_loop))
    assert_predicate built, :built?, built.refusal.inspect
    input = JSON.parse(built.request.payload).fetch("input")
    reasoning = input.index { |item| item["type"] == "reasoning" }
    call = input.index { |item| item["type"] == "function_call" }
    assert_equal({ "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => REASONING }] },
      input[reasoning])
    assert_operator reasoning, :<, call, "the thought rides before the call it produced"
    assert_empty input.select { |item| item["role"] == "assistant" },
      "a tool-only round adds no assistant message: no empty answer, no fence"
  end

  test "a summary preserves first-read DeepSeek reasoning before its call without restoring the old answer" do
    agent_loop = seed(model("ask", "model" => { "model" => "deepseek/deepseek-flash", "reasoning_effort" => "high" },
      "prompt" => "Read the marker", "tools" => [LoopLaneTestHelper::READ_TOOL]))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, tool_only_response(answer: "The answer replaced by compaction."))
    assert_equal "The answer replaced by compaction.", loop_node(agent_loop, "ask").output_body.effective_text
    settled = AgentLoops::Parks::Settle.call(node: loop_node(agent_loop, "r1t0"), trusted: true,
      content: "marker contents", outcome: "completed")
    assert_predicate settled, :applied?
    complete_compaction_summary(loop_node(agent_loop, "r1"))
    schedule_loop!(agent_loop)

    built = build(loop_attempt(agent_loop))
    assert_predicate built, :built?, built.refusal.inspect
    input = JSON.parse(built.request.payload).fetch("input")
    reasoning = input.index { |item| item["type"] == "reasoning" }
    call = input.index { |item| item["type"] == "function_call" }
    assert_not_nil reasoning, "compaction must retain the provider-required reasoning of an unread call"
    assert_not_nil call
    assert_equal({ "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => REASONING }] },
      input[reasoning])
    assert_operator reasoning, :<, call
    assert_equal ["read-marker", "read_file", '{"path":"marker"}'],
      input[call].values_at("call_id", "name", "arguments")
    outputs = input.select { |item| item["type"] == "function_call_output" }
    assert_equal [["read-marker", "marker contents"]], outputs.map { |item| item.values_at("call_id", "output") }
    assert_includes input.to_json, "COMPACTED HISTORY"
    refute_includes input.to_json, "The answer replaced by compaction."
    assert_empty input.select { |item| item["role"] == "assistant" }
  end

  private

    def tool_only_response(answer: nil)
      completed = {
        "type" => "response.completed",
        "response" => {
          "id" => "reasoning-replay-response", "status" => "completed",
          "output" => [
            { "type" => "reasoning", "id" => "reasoning-1",
              "content" => [{ "type" => "reasoning_text", "text" => REASONING }] },
            *(answer ? [{ "type" => "message", "id" => "answer-1", "role" => "assistant", "status" => "completed",
              "content" => [{ "type" => "output_text", "text" => answer }] }] : []),
            *function_call_items([{ id: "read-marker", name: "read_file", arguments: '{"path":"marker"}' }]),
          ],
          "usage" => { "input_tokens" => 2, "output_tokens" => 4 },
        },
      }
      { status: 200, headers: { "content-type" => "text/event-stream" },
        sse: ["data: #{JSON.generate(completed)}\n\n", "data: [DONE]\n\n"] }
    end
end
