require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationListingTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "activity order pages microseconds and UUID ties in both directions while the default stays public id" do
    rows = [200, 100, 200, 300].map do |microseconds|
      Conversation.create!(workspace: @workspace, creating_user: @human,
        last_activity_at: Time.utc(2026, 10, 7, 12, 0, 0, microseconds))
    end
    assert_equal rows.map(&:public_id).sort, list_ids(conversations_path)
    expected = rows.sort_by { |row| [row.last_activity_at, row.public_id] }.map(&:public_id)

    assert_equal expected, walk_activity_pages(conversations_path, order: "asc", count: rows.length)
    assert_equal expected.reverse, walk_activity_pages(conversations_path, order: "desc", count: rows.length)
  end

  test "working side archived and children activity lists keep their existing filters" do
    older = Time.utc(2026, 10, 7, 12)
    newer = older + 1.hour
    root = Conversation.create!(workspace: @workspace, creating_user: @human, last_activity_at: older)
    recent = Conversation.create!(workspace: @workspace, creating_user: @human, last_activity_at: newer)
    side = fork_over_http(root, side: true)
    root.update!(last_activity_at: older)
    archived = Conversation.create!(workspace: @workspace, creating_user: @human,
      last_activity_at: newer, archived_at: newer)
    older_archived = Conversation.create!(workspace: @workspace, creating_user: @human,
      last_activity_at: older, archived_at: newer)
    child = Conversation.create!(workspace: @workspace, creating_user: @human,
      parent_conversation: root, parent_conversation_public_id: root.public_id, last_activity_at: older)
    archived_child = Conversation.create!(workspace: @workspace, creating_user: @human,
      parent_conversation: root, parent_conversation_public_id: root.public_id,
      last_activity_at: newer, archived_at: newer)
    Conversation.create!(workspace: @workspace, creating_user: @human, tombstoned_at: newer)
    Conversation.create!(workspace: @workspace, creating_user: users(:owner), access_default: :none)
    options = { order_by: "last_activity_at", order: "desc" }

    assert_equal [recent.public_id, root.public_id], list_ids(conversations_path, **options)
    assert_equal [side.public_id], list_ids(conversations_path, **options, side: "1")
    assert_equal [archived.public_id, older_archived.public_id],
      walk_activity_pages(archived_conversations_path, order: "desc", count: 2)
    assert_equal [archived_child.public_id, child.public_id],
      walk_activity_pages("#{conversation_path(root)}/children", order: "desc", count: 2)
  end

  test "an activity cursor is bound to its key shape and direction and rejects malformed timestamps" do
    2.times { create_conversation! }
    list_ids(conversations_path, order_by: "last_activity_at", order: "desc", limit: 1)
    cursor = response.parsed_body.dig("pagination", "next_after")
    [
      { order: "desc", after: cursor },
      { order_by: "last_activity_at", order: "asc", after: cursor },
      { order_by: "updated_at" },
      { order_by: "last_activity_at", after: Base64.urlsafe_encode64(JSON.generate(
        "dir" => "asc", "last_activity_at" => "yesterday", "public_id" => SecureRandom.uuid_v7
      )) },
    ].each do |params|
      get conversations_path, headers: auth, params: params
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end
  end

  test "forks expose their direct source on Basic and Full even when their boundary is inherited" do
    root = create_conversation!
    2.times do |index|
      post conversation_inputs_path(root), headers: auth("source-input-#{index}"), as: :json,
        params: { input: { text: "message #{index}" } }
      assert_response :accepted
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    end
    inherited, boundary = root.conversation_turns.order(:position).to_a
    branch = fork_over_http(root, turn_public_id: boundary.public_id)
    descendant = fork_over_http(branch, turn_public_id: inherited.public_id)

    assert_source_on_full(branch, root.public_id)
    assert_source_on_full(descendant, branch.public_id)
    get conversations_path, headers: auth
    sources = response.parsed_body.fetch("conversations").to_h do |row|
      [row.fetch("public_id"), row.fetch("source_conversation_public_id")]
    end
    assert_equal({ root.public_id => nil, branch.public_id => root.public_id,
      descendant.public_id => branch.public_id }, sources)
    assert_nil response.parsed_body.fetch("conversations").find { |row| row["public_id"] == branch.public_id }.fetch("parent")
  end

  test "an empty Side names its source without a fork turn and lists sources in one batch" do
    root = create_conversation!
    side = fork_over_http(root, side: true)
    assert_source_on_full(side, root.public_id)
    assert_nil response.parsed_body.dig("conversation", "forked_from_turn_public_id")
    get conversations_path, headers: auth, params: { side: "1" }
    one = sql_count { get conversations_path, headers: auth, params: { side: "1" } }
    assert_equal root.public_id, response.parsed_body.fetch("conversations").sole.fetch("source_conversation_public_id")

    other_sources = 2.times.map { create_conversation! }
    other_sources.each { |source| fork_over_http(source, side: true) }
    three = sql_count { get conversations_path, headers: auth, params: { side: "1" } }
    assert_equal [root, *other_sources].map(&:public_id).sort,
      response.parsed_body.fetch("conversations").map { |row| row.fetch("source_conversation_public_id") }.sort
    assert_equal one, three, "more direct ancestors do not add a query per conversation"
  end

  test "source readability is checked now and hidden or tombstoned sources render null" do
    source = Conversation.create!(workspace: @workspace, creating_user: users(:owner))
    branch = fork_over_http(source, side: true)
    assert_source_on_full(branch, source.public_id)

    source.update!(access_default: :none)
    assert_source_on_full(branch, nil)
    get conversations_path, headers: auth, params: { side: "1" }
    assert_nil response.parsed_body.fetch("conversations").sole.fetch("source_conversation_public_id")

    source.update!(access_default: :read, archived_at: Time.current)
    assert_source_on_full(branch, source.public_id)

    source.update!(tombstoned_at: Time.current)
    assert_source_on_full(branch, nil)
  end

  private

    def list_ids(path, **params)
      get path, headers: auth, params: params
      assert_response :success
      response.parsed_body.fetch("conversations").map { |row| row.fetch("public_id") }
    end

    def walk_activity_pages(path, order:, count:)
      ids = []
      after = nil
      count.times do
        ids.concat(list_ids(path, order_by: "last_activity_at", order: order, limit: 1, after: after))
        after = response.parsed_body.dig("pagination", "next_after")
      end
      assert_nil after, "the final row ends the walk"
      assert_equal count, ids.uniq.length, "each stable row appears exactly once"
      ids
    end

    def fork_over_http(source, **params)
      post conversation_forks_path(source), headers: auth(SecureRandom.uuid_v7), as: :json,
        params: { fork: params }
      assert_response :created
      assert_equal source.public_id, response.parsed_body.dig("conversation", "source_conversation_public_id")
      Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    end

    def assert_source_on_full(conversation, source_public_id)
      get conversation_path(conversation), headers: auth
      assert_response :success
      actual = response.parsed_body.fetch("conversation").fetch("source_conversation_public_id")
      if source_public_id.nil?
        assert_nil actual
      else
        assert_equal source_public_id, actual
      end
    end
end
