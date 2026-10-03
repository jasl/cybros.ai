require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationCallbacksTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_an_independent_result_keeps_its_exact_request_and_sample_after_materialization
    fixture = contract.fetch("valid_callback_input_fixture")
    result = fixture.fetch("input").fetch("callback_result")
    accepted = chat([[202, {}, fixture]]).inputs.create(text: "Read the result", idempotency_key: "callback")
    assert_equal result, wire(accepted.input.callback_result)

    row = contract.fetch("valid_callback_turn_fixture")
    ["message", "direct_reply"].each do |kind|
      turn = parse_turn(row.merge("kind" => kind))
      assert_equal row.fetch("input_public_id"), turn.input_public_id
      assert_equal row.fetch("callback_sources"), wire(turn).fetch("callback_sources")
      assert_equal row.fetch("sender_agent_loop_public_id"), turn.sender_agent_loop_public_id
      assert_equal result.fetch("variant_public_id"), turn.callback_sources.first.result.variant_public_id
      refute_equal turn.active_variant.public_id, turn.callback_sources.first.result.variant_public_id
    end
  end

  def test_a_parent_summary_preserves_each_source_without_inventing_a_single_execution_owner
    row = contract.fetch("valid_callback_batch_turn_fixture")
    sources = row.fetch("callback_sources")
    turn = parse_turn(row)

    assert_nil turn.sender_agent_loop_public_id
    assert_nil turn.sender_conversation_public_id
    assert_nil turn.sender_task_key
    assert_equal sources, wire(turn).fetch("callback_sources")
    assert_equal sources.map { |source| source.fetch("result").fetch("input_public_id") },
      turn.callback_sources.map { |source| source.result.input_public_id }
    assert_equal sources.map { |source| source.fetch("result").fetch("variant_public_id") },
      turn.callback_sources.map { |source| source.result.variant_public_id }
  end

  def test_an_ordinary_turn_has_no_worker_result_but_a_partial_result_reference_is_malformed
    page = contract.fetch("valid_turns_fixture")
    page = page.merge("turns" => [page.fetch("turns").first.except("input_public_id", "callback_sources")])
    ordinary = chat([[200, {}, page]]).turns.list.first
    assert_nil ordinary.input_public_id
    assert_empty ordinary.callback_sources
    input = chat([[202, {}, contract.fetch("valid_input_fixture")]]).inputs.create(text: "Hello", idempotency_key: "ordinary").input
    assert_nil input.callback_result

    source = callback_source.merge("result" => callback_result.except("variant_public_id"))
    assert_raises(CybrosAgent::Api::MalformedResponse) { read_turn(sources: [source]) }
  end

  def test_an_unknown_requester_does_not_erase_the_exact_worker_result
    result = callback_result.merge("requester_actor_public_id" => nil)
    fixture = contract.fetch("valid_input_fixture")
    fixture = fixture.merge("input" => fixture.fetch("input").merge("callback_result" => result))
    input = chat([[202, {}, fixture]]).inputs.create(text: "Result", idempotency_key: "unknown-requester").input
    assert_nil input.callback_result.requester_actor_public_id
    assert_equal result, wire(input.callback_result)

    turn = read_turn(sources: [callback_source.merge("result" => result)])
    assert_equal result, wire(turn.callback_sources.first.result)
  end

  private

    def callback_result(suffix = "a")
      { "conversation_public_id" => "worker-conversation-#{suffix}", "input_public_id" => "worker-input-#{suffix}",
        "turn_public_id" => "worker-turn-#{suffix}", "variant_public_id" => "worker-variant-#{suffix}",
        "requester_actor_public_id" => "requester-actor" }
    end

    def callback_source(suffix = "a")
      { "input_public_id" => "receipt-#{suffix}", "origin" => "child", "sender_conversation_public_id" => "worker-conversation-#{suffix}",
        "sender_agent_loop_public_id" => "source-loop-#{suffix}", "sender_task_key" => "r1t0", "result" => callback_result(suffix) }
    end

    def read_turn(sources:)
      row = contract.fetch("valid_callback_batch_turn_fixture")
        .merge("input_public_id" => sources.last.fetch("input_public_id"), "callback_sources" => sources)
      parse_turn(row)
    end

    def parse_turn(row)
      page = contract.fetch("valid_turns_fixture")
      chat([[200, {}, page.merge("turns" => [row])]]).turns.list.first
    end

    def wire(value) = JSON.parse(JSON.generate(value.to_h))
end
