require "test_helper"
require_relative "../../test_helpers/compaction_summary_test_helper"

class AgentRuns::GeminiReplayTest < ActiveJob::TestCase
  include InvocationHarness
  include CompactionSummaryTestHelper

  MODEL = "gemini/gemini-3.8-flash".freeze
  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze
  SIGNATURES = { "call_first" => "signature-first", "call_second" => "signature-second" }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "gemini", api_key: "test-only-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "gemini", expected_lock_version: nil)
  end

  test "same-model continuation returns each Gemini tool signature on its function call" do
    assert_signatures_replayed(thought: "Read both files before comparing them.")
  end

  test "same-model continuation preserves tool signatures without a thought summary" do
    assert_signatures_replayed(thought: nil)
  end

  test "same-model continuation preserves signatures when Gemini omits function call ids" do
    assert_signatures_replayed(thought: "Read both files before comparing them.", provider_ids: [nil, nil])
  end

  test "pruned history preserves each native signature beside its cleared result" do
    assert_signatures_replayed(thought: "Read both files before comparing them.", prune: true)
  end

  test "a summary preserves first-read Gemini signatures without restoring the old answer" do
    assert_signatures_replayed(thought: "Read both files before comparing them.", summary: true)
  end

  test "native call ids follow normalized result ids when a supplied id collides with a generated id" do
    assert_signatures_replayed(thought: "Read both files before comparing them.",
      provider_ids: [nil, "#{Nexus::ModelToolCalls::SYNTHETIC_ID_PREFIX}0"])
  end

  private

    def assert_signatures_replayed(thought:, provider_ids: SIGNATURES.keys, prune: false, summary: false)
      steps = [model("ask", "model" => { "model" => MODEL, "reasoning_effort" => "low" },
        "prompt" => "Compare the two files", "tools" => [READ_TOOL])]
      if prune
        steps << model("after_read", "model" => { "model" => MODEL, "reasoning_effort" => "low" },
          "prompt" => "Keep comparing", "tools" => [READ_TOOL])
      end
      agent_run = seed(*steps)
      AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
      schedule(agent_run)

      answer = "The answer replaced by compaction." if summary
      apply_via(attempt_for(agent_run, "ask"), gemini_response(thought: thought, provider_ids: provider_ids, answer: answer))
      AgentRuns::ConvergeTerminalSteps.call
      schedule(agent_run)

      source = agent_run.agent_run_tasks.find_by!(node_key: "ask")
      assert_equal "completed", source.status
      assert_equal answer, source.output_body.effective_text if summary
      trace = source.invocation_body("reasoning_trace").content_body_entries.sole.content_fragment.payload
      assert_equal SIGNATURES.values, trace.fetch("items")
        .select { |item| item["kind"] == "tool_call" }
        .map { |item| item.fetch("signature") },
        "the provider response must reach durable capture before testing replay"
      call_ids = source.tool_calls_body.content_body_entries.sole.content_fragment.payload.fetch("items")
        .map { |call| call.fetch("id") }
      expected_signatures = call_ids.zip(SIGNATURES.values).to_h

      %w[r1t0 r1t1].each do |key|
        tool = agent_run.agent_run_tasks.find_by!(node_key: key)
        assert_equal "dispatched", tool.status
        result = AgentRuns::Parks::Settle.call(node: tool, trusted: true,
          content: "contents of #{tool.tool_input.fetch("path")}".ljust(prune ? 1_000 : 0, "x"), outcome: "completed")
        assert_predicate result, :applied?
      end
      continuation = agent_run.agent_run_tasks.find_by!(node_key: "r1")
      complete_compaction_summary(continuation) if summary
      if prune
        schedule(agent_run)
        results = continuation.reload.invocation_body("request").content_body_entries.map { |entry| entry.content_fragment.payload }
          .select { |entry| entry["type"] == "tool_result_item" }
        assert_equal SIGNATURES.keys.map { |key| "contents of #{key}".ljust(1_000, "x") },
          results.map { |entry| entry.dig("payload", "output") },
          "each result reaches its first consumer before it becomes eligible for clearing"
        apply_via(attempt_for(agent_run, "r1"), gemini_response(thought: nil, provider_ids: [], answer: "I read both files."))
        AgentRuns::ConvergeTerminalSteps.call
        agent_run.with_lock do
          after_read = agent_run.agent_run_tasks.find_by!(node_key: "after_read")
          repair = Conversations::Compaction::Arm.call(agent_run: agent_run, node: after_read,
            trigger: Conversations::Compaction::Trigger.wall(after_read,
              overshoot: Conversations::Compaction::Overshoot.bytes(100)))
          assert_predicate repair, :pruned?
        end
      end
      schedule(agent_run)
      target_key = prune ? "after_read" : "r1"

      if prune
        continuation = agent_run.agent_run_tasks.find_by!(node_key: target_key)
        results = continuation.invocation_body("request").content_body_entries.map { |entry| entry.content_fragment.payload }
          .select { |entry| entry["type"] == "tool_result_item" }
        assert_equal [AgentRuns::RoundReplay::Pairing::CLEARED] * 2,
          results.map { |entry| entry.dig("payload", "output") }
      end

      built = build(attempt_for(agent_run, target_key))
      assert_predicate built, :built?, built.refusal.inspect
      wire = JSON.parse(built.request.payload)
      parts = wire.fetch("contents").flat_map { |message| message.fetch("parts") }
      calls = parts.select { |part| part.key?("functionCall") }
      assert_equal expected_signatures, calls.to_h { |part| [part.fetch("functionCall").fetch("id"), part["thoughtSignature"]] },
        "the continuation must return each captured signature to the actual Gemini wire"
      assert_equal SIGNATURES.keys, calls.map { |part| part.dig("functionCall", "args", "path") },
        "normalizing pairing identity preserves the provider's original arguments"
      assert_equal call_ids, parts.filter_map { |part| part.dig("functionResponse", "id") },
        "the signed calls remain paired with their settled results"
      if summary
        assert_includes wire.to_json, "COMPACTED HISTORY"
        refute_includes wire.to_json, answer
      end
    end

    def schedule(agent_run)
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    def attempt_for(agent_run, key)
      invocation_id = agent_run.agent_run_tasks.find_by!(node_key: key).selected_model_invocation_id
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted
        .find { |candidate| candidate.invocation.id == invocation_id }
      assert admitted, "the scheduled round must be admitted through the shipped Gemini lane"
      clear_enqueued_jobs
      admitted.attempt
    end

    def gemini_response(thought:, provider_ids:, answer: nil)
      parts = thought ? [{ "thought" => true, "text" => thought }] : []
      parts << { "text" => answer } if answer
      parts += SIGNATURES.first(provider_ids.length).each_with_index.map do |(call_id, signature), index|
        { "thoughtSignature" => signature,
          "functionCall" => { "id" => provider_ids[index], "name" => "read_file", "args" => { "path" => call_id } }.compact }
      end
      payload = {
        "responseId" => "gemini-replay-response",
        "candidates" => [{ "content" => { "role" => "model", "parts" => parts }, "finishReason" => "STOP" }],
        "usageMetadata" => { "promptTokenCount" => 2, "candidatesTokenCount" => 3,
                             "thoughtsTokenCount" => 5, "totalTokenCount" => 10 },
      }
      { status: 200, headers: { "content-type" => "text/event-stream" },
        sse: ["data: #{JSON.generate(payload)}\n\n"] }
    end
end
