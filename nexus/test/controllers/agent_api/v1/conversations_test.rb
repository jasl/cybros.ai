require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "create is 201, replay is the standing resource, mismatch is 409" do
    post conversations_path, headers: auth("c-1"), as: :json,
      params: { conversation: { title: "Field notes" } }

    assert_response :created
    assert_equal "false", response.headers["Idempotency-Replayed"]
    public_id = response.parsed_body.dig("conversation", "public_id")
    assert_equal "Field notes", response.parsed_body.dig("conversation", "title")

    post conversations_path, headers: auth("c-1"), as: :json,
      params: { conversation: { title: "Field notes" } }
    assert_response :created
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal public_id, response.parsed_body.dig("conversation", "public_id")
    assert_equal 1, Conversation.count

    post conversations_path, headers: auth("c-1"), as: :json,
      params: { conversation: { title: "Different" } }
    assert_response :conflict
    assert_nil response.headers["Idempotency-Replayed"]
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  # The creator names its runner: a live runner-kind row eligible for the creator binds, anything
  # else is refused by name, and the field rides the idempotency envelope — a replay without it is a
  # different request.
  test "create names its runner, refuses an ineligible one, and digests the name" do
    runner = connect_runner(manager: users(:owner), registration_identifier: "wide-1",
      assignment_scope: :account_wide).executor_access_token.task_executor
    address = task_executors(:address)

    post conversations_path, headers: auth("c-runner-bad"), as: :json,
      params: { conversation: { default_runner_executor_public_id: address.public_id } }
    assert_response :unprocessable_entity
    assert_equal "runner_not_eligible", response.parsed_body.dig("error", "code")
    assert_equal 0, Conversation.count

    post conversations_path, headers: auth("c-runner"), as: :json,
      params: { conversation: { default_runner_executor_public_id: runner.public_id } }
    assert_response :created
    assert_equal runner.id, Conversation.last.default_runner_executor_id

    post conversations_path, headers: auth("c-runner"), as: :json, params: { conversation: {} }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal 1, Conversation.count
  end

  # The creator names the ANSWERER: an agent profile of the account that may write here answers the
  # conversation, whoever created it; anything else is refused by name; the field rides the
  # idempotency envelope — a replay without it is a different request.
  test "create names its answerer, refuses an ineligible one, and digests the name" do
    post conversations_path, headers: auth("c-answerer-bad"), as: :json,
      params: { conversation: { answering_user_public_id: users(:owner).public_id } }
    assert_response :unprocessable_entity
    assert_equal "answerer_not_eligible", response.parsed_body.dig("error", "code")
    assert_equal 0, Conversation.count

    post conversations_path, headers: auth("c-answerer"), as: :json,
      params: { conversation: { answering_user_public_id: users(:agent).public_id } }
    assert_response :created
    assert_equal users(:agent).public_id, response.parsed_body.dig("conversation", "answering_user_public_id")
    assert_equal users(:agent).id, Conversation.last.answering_user_id

    post conversations_path, headers: auth("c-answerer"), as: :json, params: { conversation: {} }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal 1, Conversation.count

    post conversations_path, headers: auth("c-mine"), as: :json, params: { conversation: {} }
    assert_response :created
    assert_equal @human.public_id, response.parsed_body.dig("conversation", "answering_user_public_id"),
      "omitted, the creator answers its own conversation"
  end

  # AN UNTITLED CONVERSATION IS THE ORDINARY FIRST ONE — every chat
  # product creates it and names it later — and the strict envelope made
  # it unreachable over HTTP: a body with no typed fields filters to an
  # empty permitted set, which `expect` answers with 400. Found by the
  # SDK's own journey, which is the only caller that sends the ordinary
  # shape.
  test "a conversation with no fields at all creates, titled or not" do
    post conversations_path, headers: auth("c-bare"), as: :json,
      params: { conversation: {} }

    assert_response :created
    assert_nil response.parsed_body.dig("conversation", "title")

    post conversations_path, headers: auth("c-absent"), as: :json, params: {}
    assert_response :created
    assert_equal 2, Conversation.count
  end

  test "the working list hides the bin and the followers; the bin has its own view" do
    working = create_conversation!(title: "working")
    binned = create_conversation!(title: "binned")
    follower = Conversation.create!(
      workspace: @workspace, creating_user: @human,
      parent_conversation: working, parent_conversation_public_id: working.public_id
    )
    Conversations::Archive.call(conversation: binned)

    get conversations_path, headers: auth
    titles = response.parsed_body.fetch("conversations").map { |c| c["title"] }
    assert_equal ["working"], titles
    assert_equal [@human.public_id],
      response.parsed_body.fetch("conversations").map { |c| c["answering_user_public_id"] },
      "the listing shape says who answers"

    get archived_conversations_path, headers: auth
    assert_equal ["binned"],
      response.parsed_body.fetch("conversations").map { |c| c["title"] }
    assert_equal [@human.public_id],
      response.parsed_body.fetch("conversations").map { |c| c["answering_user_public_id"] }

    get conversation_path(follower), headers: auth
    assert_response :success, "a follower is readable through its id, never listed"
  end

  # The listing preloads the answerer: more rows with more distinct answerers cost the same queries
  # — a fourth listing without the preload would be the N+1 this pin catches.
  test "the working list carries the answerer without a query per row" do
    create_conversation!(title: "one")
    get conversations_path, headers: auth, as: :json
    one = sql_count { get conversations_path, headers: auth }
    assert_equal 1, response.parsed_body.fetch("conversations").length

    Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    Conversation.create!(workspace: @workspace, creating_user: users(:owner))
    three = sql_count { get conversations_path, headers: auth }
    rows = response.parsed_body.fetch("conversations")
    assert_equal 3, rows.length
    assert_equal [users(:owner), users(:agent), @human].map(&:public_id).sort,
      rows.map { |c| c["answering_user_public_id"] }.sort
    assert_equal one, three, "three rows, three answerers, the same queries"
  end

  test "the whole flow: input, drain, timeline, archive gate, tombstone absence" do
    conversation = create_conversation!

    post conversation_inputs_path(conversation), headers: auth("i-1"), as: :json,
      params: { input: { text: "hello there" } }
    assert_response :accepted
    assert_equal "pending", response.parsed_body.dig("input", "state")

    perform_enqueued_jobs only: Conversations::Inputs::DrainJob

    get conversation_turns_path(conversation), headers: auth
    turns = response.parsed_body.fetch("turns")
    assert_equal 1, turns.length
    assert_equal "hello there", turns.first.dig("active_variant", "content")
    assert_not turns.first.fetch("active_variant").key?("prompt_text"),
      "a message turn's content IS the person's words: no prompt_text beside it"
    assert_not turns.first.fetch("inherited")

    post archive_conversation_path(conversation), headers: auth, as: :json
    assert_response :success
    assert_not_nil response.parsed_body.dig("conversation", "archived_at")

    post conversation_inputs_path(conversation), headers: auth("i-2"), as: :json,
      params: { input: { text: "into the bin" } }
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")

    post unarchive_conversation_path(conversation), headers: auth, as: :json
    assert_response :success

    delete conversation_path(conversation), headers: auth
    assert_response :no_content

    get conversation_path(conversation), headers: auth
    assert_response :not_found, "the condemned phase conceals like absence"
  end

  # THE END IS A PERSISTED EVENT: DELETE narrates `conversation_ended` as the feed's last item — the
  # cable delivers it to a socket follower — and the next poll is the family 404, which is what a
  # poller reads as the same fact. The reap destroys the row later.
  test "DELETE narrates conversation_ended, then the next poll is 404" do
    conversation = create_conversation!
    get conversation_events_path(conversation), headers: auth
    assert_response :success, "the feed served before the end"

    streams = capture_broadcasts("agent_api:v1:conversation:#{conversation.public_id}:events") do
      delete conversation_path(conversation), headers: auth
    end
    assert_response :no_content

    item = ConversationEventItem.where(host: conversation, item_type: "conversation_ended").sole
    assert_equal({ "reason" => "tombstoned", "conversation_public_id" => conversation.public_id }, item.payload)
    assert_equal item.sequence, ConversationEventItem.where(host: conversation).maximum(:sequence),
      "the last item the feed carries"
    assert_equal ["conversation_ended"], streams.map { |message| message.dig("event", "type") }

    get conversation_events_path(conversation), headers: auth
    assert_response :not_found, "the condemned phase conceals the feed like absence"
  end

  test "a refused body leaves no phantom: zero rows, zero events, through the wrapper" do
    conversation = create_conversation!

    post conversation_inputs_path(conversation), headers: auth("ph-1"), as: :json,
      params: { input: { entries: Array.new(Nexus::SizeBounds.fetch(:body_entry_count_bound) + 1) { { "text" => "x" } } } }

    assert_response :unprocessable_entity
    assert_equal "content_items_too_many", response.parsed_body.dig("error", "code")
    assert_equal 0, ConversationInput.count,
      "the savepoint holds under the receipt wrapper's transaction"
    assert_equal 0, ConversationEventItem.count, "no narration for what never happened"
  end

  test "lifecycle verbs are writes: a read-only caller cannot touch the bin or the clock" do
    conversation = create_conversation!
    @workspace.update!(state: :archiving)

    post archive_conversation_path(conversation), headers: auth, as: :json
    assert_response :forbidden

    delete conversation_path(conversation), headers: auth
    assert_response :forbidden
    assert_not conversation.reload.tombstoned?, "browsable is not writable"
  end

  test "PATCH renames outside the bin; children list the followers" do
    conversation = create_conversation!(title: "before")
    follower = Conversation.create!(
      workspace: @workspace, creating_user: @human,
      parent_conversation: conversation,
      parent_conversation_public_id: conversation.public_id
    )

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: "after" } }
    assert_response :success
    assert_equal "after", response.parsed_body.dig("conversation", "title")

    get "#{conversation_path(conversation)}/children", headers: auth
    assert_equal [follower.public_id],
      response.parsed_body.fetch("conversations").map { |c| c["public_id"] }
    assert_equal({ "public_id" => conversation.public_id, "spawn_node_key" => nil, "label" => nil },
      response.parsed_body.fetch("conversations").sole.fetch("parent"),
      "a follower names its parent as one block; the listing prints it")
    get conversation_path(conversation), headers: auth
    assert_nil response.parsed_body.dig("conversation", "parent"), "a top-level row says nil"

    Conversations::Archive.call(conversation: conversation.reload)
    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: "in the bin" } }
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")
  end
end
