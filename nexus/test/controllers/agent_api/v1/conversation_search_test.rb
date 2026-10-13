require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationSearchTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "Chinese segmentation and English stemming match a final field and return its literal neighborhood" do
    conversation = create_conversation!(title: "日常笔记")
    append_message(conversation, "前言 " * 500 + "中国人民热爱人工智能，RUNNING searches improved." + " 后记" * 500)
    get search_path, headers: auth, params: { query: "人工智能 runs SEARCH" }
    assert_response :success
    match = response.parsed_body.fetch("matches").sole
    assert_equal conversation.public_id, match.fetch("conversation_public_id")
    assert_equal "content", match.fetch("field")
    assert_equal Nexus::Contract.send(:history).dig("search_fixture", "matches").sole.keys.sort, match.keys.sort
    assert_includes match.fetch("excerpt"), "人工智能"
    assert_includes match.fetch("excerpt"), "RUNNING"
    assert_operator match.fetch("excerpt").length, :<=, 500
    assert match.fetch("truncated")
    get search_path, headers: auth, params: { query: "the and" }
    assert_empty response.parsed_body.fetch("matches")
  end

  test "title maintenance archive switches and keyset pages apply before the limit" do
    conversation = create_conversation!(title: "searchable topic")
    3.times { |i| append_message(conversation, "searchable #{i}") }
    hits = []
    cursor = nil
    loop do
      get search_path, headers: auth, params: { query: "searchable", limit: 1, **(cursor ? { after: cursor } : {}) }
      assert_response :success
      hits.concat(response.parsed_body.fetch("matches"))
      cursor = response.parsed_body.dig("pagination", "next_after")
      break unless cursor
    end
    assert_equal 4, hits.length
    assert_equal 4, hits.map { |hit| [hit["turn_public_id"], hit["field"]] }.uniq.length
    conversation.reload.update!(title: "renamed", archived_at: Time.current)
    get search_path, headers: auth, params: { query: "searchable" }
    assert_empty response.parsed_body.fetch("matches")
    get search_path, headers: auth, params: { query: "searchable", archived: "only" }
    assert_equal 3, response.parsed_body.fetch("matches").length
    get search_path, headers: auth, params: { query: "renamed", archived: "include" }
    assert_equal "title", response.parsed_body.fetch("matches").sole.fetch("field")
  end

  test "fork overlays control shared prefix visibility independently and before pagination" do
    parent = create_conversation!
    append_message(parent, "sharedneedle first")
    append_message(parent, "boundary")
    first, boundary = parent.conversation_turns.order(:position).to_a
    post conversation_forks_path(parent), headers: auth("fork-search"), as: :json,
      params: { fork: { turn_public_id: boundary.public_id } }
    assert_response :created
    child = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    patch "#{conversation_turns_path(parent)}/#{first.public_id}", headers: auth, as: :json,
      params: { turn: { visibility: "hidden" } }
    assert_response :success
    get search_path, headers: auth, params: { query: "sharedneedle", limit: 1 }
    hit = response.parsed_body.fetch("matches").sole
    assert_equal child.public_id, hit.fetch("conversation_public_id")
    assert hit.fetch("inherited")
    get "#{conversation_path(child)}/history", headers: auth, params: { around_turn_public_id: first.public_id }
    assert_response :success
    assert_includes response.parsed_body.fetch("turns").map { |row| row.fetch("content", "") }, "sharedneedle first"
    patch "#{conversation_turns_path(child)}/#{first.public_id}", headers: auth, as: :json,
      params: { turn: { concealed: true } }
    assert_response :success
    get search_path, headers: auth, params: { query: "sharedneedle" }
    assert_empty response.parsed_body.fetch("matches")
    get "#{conversation_path(child)}/history", headers: auth, params: { around_turn_public_id: first.public_id }
    assert_response :not_found
  end

  test "tombstones and reasoning are not search sources" do
    conversation = create_conversation!
    append_message(conversation, "visibleword")
    turn = conversation.conversation_turns.sole
    variant = turn.active_variant
    ContentBodies::Replace.call(owner: variant, role: "reasoning", entries: [{ "text" => "reasoningsecret" }], seal: true)
    get search_path, headers: auth, params: { query: "reasoningsecret" }
    assert_empty response.parsed_body.fetch("matches")
    conversation.reload.update!(tombstoned_at: Time.current)
    get search_path, headers: auth, params: { query: "visibleword", archived: "include", include_auxiliary: true }
    assert_empty response.parsed_body.fetch("matches")
    get "#{conversation_path(conversation)}/history", headers: auth
    assert_response :not_found
  end

  test "ACL filtering precedes pagination and history discovery" do
    conversation = create_conversation!(title: "hiddenneedle")
    append_message(conversation, "hiddenneedle")
    conversation.reload.update!(access_default: "none")
    other = create_access_token_fixture(user: users(:curator), name: "Other reader")
    headers = { "Authorization" => "Bearer #{other.secret}" }
    get search_path, headers: headers, params: { query: "hiddenneedle", limit: 1 }
    assert_response :success
    assert_empty response.parsed_body.fetch("matches")
    assert_nil response.parsed_body.dig("pagination", "next_after")
    get "#{conversation_path(conversation)}/history", headers: headers
    assert_response :not_found
  end

  test "sealing a near-bound final body indexes its tail without indexing streaming or execution bodies" do
    conversation = create_conversation!
    append_message(conversation, "initial")
    variant = conversation.conversation_turns.sole.active_variant
    body = ContentBodies::Replace.call(owner: variant, role: "prompt",
      entries: [{ "text" => "ordinary " * 116_000 + " finaltailneedle" }]).body
    assert_empty body.search_terms
    body.seal
    assert_includes body.search_terms, "finaltailneedl"
    get search_path, headers: auth, params: { query: "finaltailneedle" }
    assert_response :success
    assert_includes response.parsed_body.fetch("matches").sole.fetch("excerpt"), "finaltailneedle"
  end

  test "history is bounded and invalid cursors cannot reach hidden content" do
    conversation = create_conversation!
    3.times { append_message(conversation, "longword " * 2_000) }
    get "#{conversation_path(conversation)}/history", headers: auth, params: { limit: 2 }
    assert_response :success
    body = response.parsed_body
    assert body.fetch("truncated")
    assert body.dig("pagination", "has_older")
    assert_not body.dig("pagination", "has_newer")
    assert_equal 4_000, body.fetch("turns").sum { |turn| turn.fetch("content", "").length }
    get search_path, headers: auth, params: { query: "longword", after: "broken" }
    assert_response :bad_request
    get "#{conversation_path(conversation)}/history", headers: auth, params: { before_position: 2, after_position: 0 }
    assert_response :bad_request
  end

  test "around history gives the target and nearest neighbors text before older long turns" do
    conversation = create_conversation!
    10.times { append_message(conversation, "old context " * 200) }
    append_message(conversation, "targetneedle " + "answer " * 300)
    target = conversation.conversation_turns.order(:position).last
    append_message(conversation, "nearest future " * 200)
    get "#{conversation_path(conversation)}/history", headers: auth,
      params: { around_turn_public_id: target.public_id.upcase }
    assert_response :success
    body = response.parsed_body
    turns = body.fetch("turns")
    assert_includes turns.find { |turn| turn.fetch("public_id") == target.public_id }.fetch("content"), "targetneedle"
    assert_includes turns.last.fetch("content"), "nearest future"
    assert_empty turns.first.fetch("content")
    assert body.fetch("truncated")
    assert_equal turns.map { |turn| turn.fetch("position") }.sort, turns.map { |turn| turn.fetch("position") }
    assert_equal 12_000, turns.sum { |turn| turn.fetch("content", "").length }
  end

  test "latest and cursor history allocate text from the requested near edge" do
    conversation = create_conversation!
    10.times { |i| append_message(conversation, "message#{i} " + "context " * 300) }
    path = "#{conversation_path(conversation)}/history"
    [
      [{}, 0, 9],
      [{ before_position: 9 }, 0, 8],
      [{ after_position: 0 }, 9, 1],
    ].each do |params, empty_position, present_position|
      get path, headers: auth, params: params
      assert_response :success
      body = response.parsed_body
      turns = body.fetch("turns")
      assert_empty turns.find { |turn| turn.fetch("position") == empty_position }.fetch("content")
      assert_includes turns.find { |turn| turn.fetch("position") == present_position }.fetch("content"), "message#{present_position}"
      assert_equal 12_000, turns.sum { |turn| turn.fetch("content", "").length }
      assert body.fetch("truncated")
    end
  end

  private

    def search_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/conversation_search"

    def append_message(conversation, text)
      post conversation_inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { text: text } }
      assert_response :accepted
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    end
end
