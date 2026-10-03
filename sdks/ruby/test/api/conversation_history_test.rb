require "test_helper"
require_relative "../support/conversation_fixtures"

class ConversationHistoryTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def search_page
    { "matches" => [{ "conversation_public_id" => CONVERSATION_ID, "title" => "中文 Rails search",
      "turn_public_id" => TURN_ID, "variant_public_id" => VARIANT_ID, "position" => 5,
      "field" => "content", "inherited" => true, "excerpt" => "memory_write 中文检索", "truncated" => false }],
      "pagination" => { "next_after" => "opaque-next" } }
  end

  def history_page
    { "conversation" => { "public_id" => CONVERSATION_ID, "title" => "中文 Rails search" },
      "turns" => [{ "public_id" => TURN_ID, "position" => 5, "kind" => "direct_reply", "role" => "assistant",
        "created_at" => "2026-09-29T00:00:00Z", "prompt" => "怎么搜索?", "content" => "Search history",
        "steers" => "包括中文", "truncated" => true }],
      "pagination" => { "before_position" => 5, "after_position" => 5, "has_older" => true, "has_newer" => false },
      "truncated" => true }
  end

  def test_search_is_scoped_to_one_workspace_with_explicit_filters_and_an_opaque_cursor
    result = conversations([[200, {}, search_page]]).search(query: "中文 memory_write", archived: "include",
      include_auxiliary: true, limit: 10, after: "opaque-before")
    assert_equal "/agent_api/v1/workspaces/#{WORKSPACE_ID}/conversation_search", request.fetch(:path)
    assert_equal({ "query" => "中文 memory_write", "archived" => "include", "include_auxiliary" => true,
      "limit" => 10, "after" => "opaque-before" }, request.fetch(:params))
    assert_equal "opaque-next", result.next_after
    assert_equal 1, result.length
    assert_equal CONVERSATION_ID, result.first.conversation_public_id
    assert_equal TURN_ID, result.first.turn_public_id
    assert_equal VARIANT_ID, result.first.variant_public_id
    assert_equal "memory_write 中文检索", result.first.excerpt
    assert_predicate result.first, :inherited?
    refute_predicate result.first, :truncated?
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
    assert_equal 5, result.before_position
    assert_equal 5, result.after_position
    assert_predicate result, :has_older?
    refute_predicate result, :has_newer?
    assert_predicate result, :truncated?
    assert_predicate result.first, :truncated?
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
    world = CybrosAgent::Api::World.new(status: "unavailable", reason: "execution_details_pruned")
    assert_predicate world, :unavailable?
    refute_predicate world, :untouched?
    assert_equal({ status: "unavailable", reason: "execution_details_pruned" }, context.restore_world(world, runner: "runner"))
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
end
