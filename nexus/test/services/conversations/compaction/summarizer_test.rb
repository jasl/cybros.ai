require "test_helper"

class Conversations::Compaction::SummarizerTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  SLOT_TEXT = "Summarize the remaining work and the files to read again.".freeze

  setup do
    @profile = users(:agent)
    @profile.prompt_documents.create!(
      account: @profile.account, slot: "summarizer", role: "system", content: SLOT_TEXT
    )
  end

  test "a delegated summarizer carries the history without reading the profile prompt" do
    step = nil
    ApplicationRecord.uncached do
      assert_no_queries_match(/FROM "prompt_documents"/) do
        summarizer = build_summarizer("mode" => "delegate", "tool_name" => "summarize_history")
        step = summarizer.step([], "Earlier work", "Keep this recent detail")
      end
    end

    assert_instance_of AgentRuns::Tasks::Step::Tool, step
    assert_equal "summarize_history", step.name
    assert_equal({
      "agent_run" => "summary-host",
      "history" => "Earlier work",
      "retained_tail" => "Keep this recent detail",
    }, step.input)
    assert_not_includes step.input.to_json, SLOT_TEXT
  end

  test "explicit and implicit kernel summarizers read the profile prompt" do
    [{ "mode" => "kernel" }, {}].each do |policy|
      ApplicationRecord.uncached do
        assert_queries_match(/FROM "prompt_documents"/, count: 1) do
          assert_equal SLOT_TEXT, build_summarizer(policy).instructions
        end
      end
    end
  end

  test "the summarizer fits the planning window when it is smaller than the hard limit" do
    selection = DevModelLane.selection(workload: "text_generation", account: @profile.account)
    limits = selection.capabilities.limits.with(effective_input_tokens: 2_000)
    selection = selection.with(capabilities: selection.capabilities.with(limits: limits))
    entries = Array.new(5) { |index| "Entry #{index}: " + ("the quick brown fox files a report. " * 100) }
    older, tail = Conversations::Compaction::Serialize.call(entries)
    summarizer = Conversations::Compaction::Summarizer.new(
      key: "summary", policy: { "mode" => "kernel" }, account: @profile.account,
      model: "dev/mock-text", reasoning_effort: nil, address: nil, selection: selection
    )
    whole = ModelRequests::TokenCount.count(profile: selection.execution_profile,
      segments: [summarizer.instructions, Conversations::Compaction::Serialize.request(older, tail)])
    assert_operator whole.tokens, :>, limits.planning_input_bound
    assert_operator whole.tokens, :<, limits.input_token_bound

    step = summarizer.step(entries, older, tail)
    fitted = ModelRequests::TokenCount.count(profile: selection.execution_profile,
      segments: [step.instructions, step.prompt])

    assert_operator fitted.tokens, :<=, limits.planning_input_bound
    assert_includes step.prompt, entries.last
    assert_includes step.prompt, "elided to fit"
  end

  test "fitting charges fixed instructions and retained tail before shrinking older entries" do
    selection = DevModelLane.selection(workload: "text_generation", account: @profile.account)
    limits = selection.capabilities.limits.with(effective_input_tokens: 1_000)
    selection = selection.with(capabilities: selection.capabilities.with(limits: limits))
    entries = Array.new(5) { |index| "Entry #{index}: " + ("the quick brown fox files a report. " * 50) }
    older, tail = Conversations::Compaction::Serialize.call(entries)
    summarizer = Conversations::Compaction::Summarizer.new(
      key: "summary", policy: { "mode" => "kernel" }, account: @profile.account,
      model: "dev/mock-text", reasoning_effort: nil, address: nil, selection: selection
    )
    fixed = ModelRequests::TokenCount.count(profile: selection.execution_profile,
      segments: [summarizer.instructions, Conversations::Compaction::Serialize.request("", tail)])
    assert_operator fixed.tokens, :<, limits.planning_input_bound

    step = summarizer.step(entries, older, tail)
    fitted = ModelRequests::TokenCount.count(profile: selection.execution_profile,
      segments: [step.instructions, step.prompt])

    assert_operator fitted.tokens, :<=, limits.planning_input_bound
    assert_includes step.prompt, entries.last
    assert_includes step.prompt, "elided to fit"
  end

  test "a byte clipped multilingual history remains a usable summary input" do
    entries = ["这是不可损坏的原始文本。" * 100, "Latest work"]
    older, tail = Conversations::Compaction::Serialize.call(entries, room: 100)

    step = build_summarizer("mode" => "kernel").step(entries, older, tail)

    assert_predicate step.prompt, :valid_encoding?
    assert_includes step.prompt, "Latest work"
    assert_not_includes step.prompt, "�"
    assert_operator Nexus::CanonicalJson.bytesize(step.prompt), :>, 0
  end

  private

    def build_summarizer(policy)
      Conversations::Compaction::Summarizer.new(
        key: "summary", policy: policy, account: @profile.account,
        model: "dev/mock-text", reasoning_effort: nil,
        address: { "agent_run" => "summary-host" }, profile: @profile
      )
    end
end
