require "test_helper"
require_relative "../../test_helpers/memory_collection_execution_test_helper"

class MemoryCollectionCompactionTest < ActiveJob::TestCase
  include MemoryCollectionExecutionTestHelper

  test "manual compaction inherits the last sample capture after binding changes and deletion" do
    first = MemoryCollection.create_for(@workspace, name: "Prior")
    second = MemoryCollection.create_for(@workspace, name: "Current")
    write_collection(first, "the original memory")
    bind(first)
    turn, source = open_turn
    run_loop_round!(source, sse_success("the retained answer"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    captured = source.memory_context
    bind(second)
    first.tombstone
    result = nil
    assert_no_difference -> { MemoryCollection.count } do
      result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
        conversation: @conversation.reload, acting_user: @human, model: "dev/mock-text"))
    end
    assert_predicate result, :accepted?, result.outcome.to_s
    summary = result.value.turn.active_variant.run
    assert_equal captured, summary.memory_context
    assert_nil summary.stopped_at
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: @conversation,
      principal: @human, configuration: summary.memory_context, agent: @agent, execution: true)
    assert_equal :memory_scope_unavailable, context.resolve("notes/fact.md").refusal
    schedule_loop!(summary)
    run_loop_round!(summary, sse_success("the compacted history"))
    Conversations::Turns::Converge.call
    assert_equal "completed", summary.reload.status
  end

  test "between-turn compaction keeps the triggering input capture while the queued input later reselects" do
    first = MemoryCollection.create_for(@workspace, name: "Trigger")
    second = MemoryCollection.create_for(@workspace, name: "Later")
    bind(first)
    _turn, source = open_turn
    run_loop_round!(source, sse_success("large previous answer", usage: { "input_tokens" => 9_000, "output_tokens" => 5 }))
    Conversations::Turns::Converge.call
    input = post_input!(@conversation.reload, acting_user: @human, text: "next reply", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")
    result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    refute_predicate result, :accepted?
    assert_equal "pending", input.reload.state
    summary = @conversation.turns.find_by!(kind: "compaction_summary").active_variant.run
    assert_equal first.public_id, summary.memory_context.dig("bindings", 0, "capture", "collection_public_id")
    bind(second)
    first.tombstone
    assert_equal first.public_id, summary.reload.memory_context.dig("bindings", 0, "capture", "collection_public_id")
    assert_nil summary.stopped_at
    schedule_loop!(summary)
    run_loop_round!(summary, sse_success("the compacted history"))
    Conversations::Turns::Converge.call
    accepted = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    assert_predicate accepted, :accepted?, accepted.outcome.to_s
    assert_equal second.public_id, accepted.value.active_variant.memory_context.dig("bindings", 0, "capture", "collection_public_id")
  end
end
