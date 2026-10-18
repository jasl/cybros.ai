require "test_helper"
require_relative "../support/conversation_fixtures"

class ConversationHistoryTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def search_page
    { "matches" => [{ "conversation_public_id" => CONVERSATION_ID, "title" => "中文 Rails search",
      "turn_public_id" => TURN_ID, "variant_public_id" => VARIANT_ID, "position" => 5,
      "field" => "content", "inherited" => true, "excerpt" => "memory_write 中文检索", "truncated" => false,
      "location" => "opaque-location" }],
      "pagination" => { "next_after" => "opaque-next" } }
  end

  def history_page
    { "conversation" => { "public_id" => CONVERSATION_ID, "title" => "中文 Rails search" },
      "turns" => [{ "public_id" => TURN_ID, "position" => 5, "kind" => "direct_reply", "role" => "assistant", "status" => "completed",
        "created_at" => "2026-09-29T00:00:00Z", "prompt" => "怎么搜索?", "content" => "Search history",
        "steers" => "包括中文", "truncated" => true }],
      "pagination" => { "before_position" => 5, "after_position" => 5, "has_older" => true, "has_newer" => false },
      "truncated" => true }
  end

  def execution
    { "turn_public_id" => TURN_ID, "variant_public_id" => VARIANT_ID, "active" => false,
      "status" => "running", "run_public_id" => "01900000-0000-7000-8000-000000000095", "run_status" => "running",
      "attention_reason" => "awaiting_human",
      "rounds" => [{ "task_key" => "r2", "mainline" => true, "status" => "completed", "visibility" => "visible",
        "text_preview" => "Checking the files", "text_bytes" => 18, "branches" => ["r2t0"],
        "calls" => { "count" => 2, "items" => [{ "task_key" => "r2t0", "name" => "bash", "status" => "completed",
          "output_preview" => "found a file", "output_bytes" => 12, "is_error" => false }] } }],
      "pagination" => { "next_before" => "opaque-execution-before", "has_older" => true }, "truncated" => true }
  end

  def test_search_is_scoped_to_one_workspace_with_explicit_filters_and_an_opaque_cursor
    result = conversations([[200, {}, search_page]]).search(query: "中文 memory_write", archived: "include",
      include_auxiliary: true, limit: 10, after: "opaque-before", answering_user_public_id: "answerer")
    assert_equal "/agent_api/v1/workspaces/#{WORKSPACE_ID}/conversation_search", request.fetch(:path)
    assert_equal({ "query" => "中文 memory_write", "archived" => "include", "include_auxiliary" => true,
      "limit" => 10, "after" => "opaque-before", "answering_user_public_id" => "answerer" }, request.fetch(:params))
    assert_equal "opaque-next", result.next_after
    assert_equal 1, result.length
    assert_equal CONVERSATION_ID, result.first.conversation_public_id
    assert_equal TURN_ID, result.first.turn_public_id
    assert_equal VARIANT_ID, result.first.variant_public_id
    assert_equal "memory_write 中文检索", result.first.excerpt
    assert_equal "opaque-location", result.first.location
    assert_predicate result.first, :inherited?
    refute_predicate result.first, :truncated?
  end

  def test_an_exact_field_uses_the_search_location_and_explicit_continuation
    fixture = CybrosAgentTest::ContractFixtures.pack("history.json").fetch("field_fixture")
    turns = chat([[200, {}, fixture], [200, {}, fixture]]).turns
    page = turns.field(TURN_ID, "variant/id", "steers", location: "opaque-location")
    assert_equal "#{PATH}/turns/#{TURN_ID}/variants/variant%2Fid/fields/steers", request.fetch(:path)
    assert_equal({ "location" => "opaque-location" }, request.fetch(:params))
    assert_equal fixture.fetch("text"), page.text
    assert_equal fixture.fetch("variant_public_id"), page.variant_public_id
    assert_equal fixture.dig("pagination", "next_after"), page.next_after
    turns.field(TURN_ID, "variant/id", "steers", after: page.next_after)
    assert_equal({ "after" => page.next_after }, request(1).fetch(:params))
    assert_raises(ArgumentError) { turns.field(TURN_ID, VARIANT_ID, "content", location: "one", after: "two") }
    assert_equal 2, @transport.requests.length
  end

  def test_a_title_only_match_needs_no_turn_and_exhaustion_is_explicit
    fixture = { "matches" => [{ "conversation_public_id" => CONVERSATION_ID, "title" => "Topic",
      "field" => "title", "inherited" => false, "excerpt" => "Topic", "truncated" => false }],
      "pagination" => { "next_after" => nil } }
    result = conversations([[200, {}, fixture]]).search(query: "Topic")
    assert_nil result.first.turn_public_id
    assert_nil result.first.position
    assert_nil result.next_after
    assert_equal({ "query" => "Topic" }, request.fetch(:params))
  end

  def test_history_reads_a_bounded_text_window_around_the_selected_turn
    result = chat([[200, {}, history_page]]).history.list(around_turn_public_id: TURN_ID, limit: 10)
    assert_equal "#{PATH}/history", request.fetch(:path)
    assert_equal({ "around_turn_public_id" => TURN_ID, "limit" => 10 }, request.fetch(:params))
    assert_equal CONVERSATION_ID, result.conversation.public_id
    assert_equal "怎么搜索?", result.first.prompt
    assert_equal "Search history", result.first.content
    assert_equal "包括中文", result.first.steers
    assert_equal "completed", result.first.status
    assert_equal 5, result.before_position
    assert_equal 5, result.after_position
    assert_predicate result, :has_older?
    refute_predicate result, :has_newer?
    assert_predicate result, :truncated?
    assert_predicate result.first, :truncated?
    assert_nil result.execution
    refute_predicate result, :execution_included?
    refute result.to_h.key?(:execution)
    assert_equal history_page, JSON.parse(JSON.generate(result.to_h))
  end

  def test_history_execution_keeps_the_running_candidate_separate_from_the_active_text
    fixture = history_page.merge("execution" => execution)
    result = chat([[200, {}, fixture]]).history.list(around_turn_public_id: TURN_ID,
      include_execution: true, execution_before: "previous-round", execution_prefix: "r1t0")

    assert_equal({ "around_turn_public_id" => TURN_ID, "include_execution" => true,
      "execution_before" => "previous-round", "execution_prefix" => "r1t0" }, request.fetch(:params))
    assert_equal "Search history", result.first.content
    assert_predicate result, :execution_included?
    trace = result.execution
    assert_equal TURN_ID, trace.turn_public_id
    assert_equal VARIANT_ID, trace.variant_public_id
    refute_predicate trace, :active?
    assert_equal "running", trace.status
    assert_equal "running", trace.run_status
    assert_equal "awaiting_human", trace.attention_reason
    assert_equal "opaque-execution-before", trace.next_before
    assert_predicate trace, :has_older?
    assert_predicate trace, :truncated?
    assert_equal "Checking the files", trace.rounds.first.text_preview
    assert_equal 1, trace.rounds.first.calls.overflow
    assert_equal "found a file", trace.rounds.first.calls.items.first.output_preview
    assert_equal execution, JSON.parse(JSON.generate(trace.to_h))
    assert_equal trace.to_h, result.to_h.fetch(:execution)
    assert_equal 1, @transport.requests.length
  end

  def test_history_distinguishes_unrequested_execution_from_requested_but_unavailable
    context = chat([[200, {}, history_page], [200, {}, history_page.merge("execution" => nil)]]).history
    omitted = context.list(include_execution: false)
    unavailable = context.list(include_execution: true)

    assert_equal({ "include_execution" => false }, request(0).fetch(:params))
    assert_equal({ "include_execution" => true }, request(1).fetch(:params))
    refute_predicate omitted, :execution_included?
    refute omitted.to_h.key?(:execution)
    assert_predicate unavailable, :execution_included?
    assert_nil unavailable.execution
    assert unavailable.to_h.key?(:execution)
    assert_nil unavailable.to_h.fetch(:execution)
  end

  def test_pruned_execution_retains_its_run_identity_without_inventing_rounds
    pruned = execution.except("attention_reason").merge("status" => "failed", "run_status" => "canceled", "rounds" => [],
      "pagination" => { "next_before" => nil, "has_older" => false }, "details_pruned_at" => "2026-10-01T00:00:00Z",
      "failure_reason" => "run_timeout", "truncated" => false)
    result = chat([[200, {}, history_page.merge("execution" => pruned)]]).history.list(include_execution: true)

    assert_empty result.execution.rounds
    assert_nil result.execution.next_before
    refute_predicate result.execution, :has_older?
    assert_equal "2026-10-01T00:00:00Z", result.execution.details_pruned_at
    assert_equal "run_timeout", result.execution.failure_reason
    assert_nil result.execution.attention_reason
    assert_equal pruned, JSON.parse(JSON.generate(result.execution.to_h))
  end

  def test_history_never_combines_windows_or_automatically_fetches_another_page
    context = chat([[200, {}, history_page], [200, {}, history_page]]).history
    context.list(before_position: 9)
    context.list(after_position: 2)
    assert_equal({ "before_position" => 9 }, request(0).fetch(:params))
    assert_equal({ "after_position" => 2 }, request(1).fetch(:params))
    assert_raises(ArgumentError) { context.list(around_turn_public_id: TURN_ID, before_position: 9) }
    assert_raises(ArgumentError) { context.list(after_position: 2, before_position: 9) }
    assert_equal 2, @transport.requests.length
  end

  def test_reclaimed_world_details_are_unavailable_without_a_restore_request
    context = chat([])
    world = CybrosAgent::Api::RunnerEffects.new(status: "unavailable", reason: "execution_details_pruned")
    assert_predicate world, :unavailable?
    refute_predicate world, :untouched?
    assert_equal({ status: "unavailable", runners: [], reason: "execution_details_pruned" }, context.restore_checkpoints(world))
    assert_empty @transport.requests
  end

  def test_the_nexus_contract_pack_parses_through_both_history_resources
    pack = CybrosAgentTest::ContractFixtures.pack("history.json")
    search = pack.fetch("search_fixture")
    read = pack.fetch("read_fixture")
    matches = conversations([[200, {}, search]]).search(query: "人工智能")
    window = chat([[200, {}, read]]).history.list(around_turn_public_id: matches.first.turn_public_id)

    assert_equal search.fetch("matches").first, matches.first.to_h.transform_keys(&:to_s)
    assert_equal read.fetch("conversation"), window.conversation.to_h.transform_keys(&:to_s)
    assert_equal read.fetch("turns").first, window.first.to_h.transform_keys(&:to_s)
    assert_equal read.fetch("pagination").fetch("has_older"), window.has_older?
    assert_equal read.fetch("pagination").fetch("has_newer"), window.has_newer?
    assert_equal read.fetch("truncated"), window.truncated?
  end

  def test_the_nexus_execution_contract_pack_round_trips_through_the_typed_history_resource
    pack = CybrosAgentTest::ContractFixtures.pack("history.json")
    %w[execution_fixture execution_pruned_fixture].each do |key|
      fixture = pack.fetch(key)
      page = chat([[200, {}, fixture]]).history.list(include_execution: true)

      assert_predicate page, :execution_included?
      assert_equal fixture, JSON.parse(JSON.generate(page.to_h))
      assert_equal 1, @transport.requests.length
    end
  end
end
