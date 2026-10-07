require "test_helper"

# THE ACCESS CARRIER ON THE WIRE: the create envelope's `access` — digested with the request, a
# principal refused by ONE name before the digest — and `PUT …/conversations/{id}/access`, the whole
# replacement under the Windows rule, answering the conversation document.
class AgentAPI::V1::Workspaces::Conversations::AccessesTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    @curator = users(:curator)
    @owner = users(:owner)
    DevModelLane.ensure_enabled!(@account)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
    @curator_secret = create_access_token_fixture(user: @curator, name: "Curator").secret
  end

  def auth(secret = @secret, key: nil)
    headers = { "Authorization" => "Bearer #{secret}" }
    headers["Idempotency-Key"] = key if key
    headers
  end

  def conversations_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations"
  def access_path(conversation) = "#{conversations_path}/#{conversation.public_id}/access"

  def entry(user, level) = { user_public_id: user.public_id, level: level }
  def by_handle(user, level) = { handle: "@#{user.handle}", level: level }

  def error_code = response.parsed_body.dig("error", "code")

  # ---- the create envelope ----

  test "create carries access, the document reads it back, and the nested envelope rides the digest" do
    body = { conversation: { title: "Restricted", access: {
      default: "none", entries: [by_handle(@curator, "read"), entry(@owner, "full")],
    } } }
    post conversations_path, headers: auth(key: "c-access"), as: :json, params: body

    assert_response :created
    access = response.parsed_body.dig("conversation", "access")
    assert_equal "none", access.fetch("default")
    assert_equal [
      { "user_public_id" => @curator.public_id, "handle" => "curator", "kind" => "human", "display_name" => "Curator",
        "level" => "read" },
      { "user_public_id" => @owner.public_id, "handle" => "owner", "kind" => "human", "display_name" => "Owner",
        "level" => "full" },
    ], access.fetch("entries"), "an entry names its principal by @handle or by public id; the document carries both"
    conversation = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    assert_equal "none", conversation.access_default
    assert_equal "read", conversation.access_level_for(@curator)

    post conversations_path, headers: auth(key: "c-access"), as: :json, params: body
    assert_response :created, "an exact replay is the standing resource"
    assert_equal conversation.public_id, response.parsed_body.dig("conversation", "public_id")

    reordered = { conversation: { title: "Restricted", access: {
      default: "none", entries: [entry(@owner, "full"), entry(@curator, "read")],
    } } }
    post conversations_path, headers: auth(key: "c-access"), as: :json, params: reordered
    assert_response :conflict, "array order is request identity: a re-ordered replay is a different request"
    assert_equal "idempotency_envelope_mismatch", error_code

    post conversations_path, headers: auth(key: "c-access"), as: :json, params: { conversation: { title: "Restricted" } }
    assert_response :conflict, "a replay without the envelope's access is a different request"
    assert_equal 1, Conversation.count

    post conversations_path, headers: auth(key: "c-plain"), as: :json, params: { conversation: {} }
    assert_response :created
    assert_equal({ "default" => "full", "entries" => [] }, response.parsed_body.dig("conversation", "access"),
      "omitted is born full with no entries")
  end

  test "create refuses an ineligible principal by one name and writes nothing — a repeated id before the digest" do
    refusals = {
      "the creator" => [entry(@human, "read")],
      "the named answerer" => [entry(users(:agent), "read")],
      "the system user" => [entry(users(:system), "read")],
      "an unknown id" => [{ user_public_id: SecureRandom.uuid_v7, level: "read" }],
      "a repeated id" => [entry(@curator, "read"), entry(@curator, "full")],
      "a repeat by the other spelling" => [entry(@curator, "read"), by_handle(@curator, "full")],
      "an unknown handle" => [{ handle: "@nobody", level: "read" }],
      "both spellings on one entry" => [{ user_public_id: @curator.public_id, handle: "owner", level: "read" }],
    }
    refusals.each_with_index do |(who, entries), index|
      post conversations_path, headers: auth(key: "c-bad-#{index}"), as: :json, params: {
        conversation: { answering_user_public_id: users(:agent).public_id, access: { entries: entries } },
      }
      assert_response :unprocessable_entity, who
      assert_equal "principal_not_eligible", error_code, who
    end
    assert_equal 0, Conversation.count
    assert_equal 0, ConversationAccessEntry.count
    assert_equal 0, ConversationCommandReceipt.count, "no receipt was written for a refused create"

    post conversations_path, headers: auth(key: "c-bad-5"), as: :json, params: {
      conversation: { access: { entries: [entry(@curator, "read")] } },
    }
    assert_response :created, "the refused key is free: nothing was digested against it"
  end

  test "create answers 422 validation_failed for an unknown level or default, never a 500" do
    post conversations_path, headers: auth(key: "c-level"), as: :json, params: {
      conversation: { access: { entries: [entry(@curator, "write")] } },
    }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", error_code

    post conversations_path, headers: auth(key: "c-default"), as: :json, params: {
      conversation: { access: { default: "owner" } },
    }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", error_code
    assert_equal 0, Conversation.count
  end

  # ---- PUT …/access ----

  test "PUT replaces the whole set, answers the document, narrates access_changed once, and the same set is a plain 200" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    body = { access: { default: "none", entries: [by_handle(@curator, "read")] } }

    put access_path(conversation), headers: auth, as: :json, params: body

    assert_response :success
    document = response.parsed_body.fetch("conversation")
    assert_equal conversation.public_id, document.fetch("public_id")
    assert_equal({ "default" => "none", "entries" => [
      { "user_public_id" => @curator.public_id, "handle" => "curator", "kind" => "human", "display_name" => "Curator",
        "level" => "read" },
    ] }, document.fetch("access"))
    assert_equal 1, conversation.conversation_event_items.where(item_type: "access_changed").count

    put access_path(conversation), headers: auth, as: :json, params: { access: { default: "none", entries: [entry(@curator, "read")] } }
    assert_response :success
    assert_not response.parsed_body.key?("error")
    assert_equal 1, conversation.conversation_event_items.where(item_type: "access_changed").count,
      "the same set by the other spelling is the same set"

    put access_path(conversation), headers: auth, as: :json,
      params: { access: { default: "none", entries: [entry(@curator, "read"), by_handle(@curator, "full")] } }
    assert_response :unprocessable_entity
    assert_equal "principal_not_eligible", error_code, "a repeat by either spelling"

    put access_path(conversation), headers: auth, as: :json, params: { access: { default: "read" } }
    assert_response :success
    assert_equal({ "default" => "read", "entries" => [] }, response.parsed_body.dig("conversation", "access"),
      "entries omitted is the empty set: a whole replacement")
    assert_equal 2, conversation.conversation_event_items.where(item_type: "access_changed").count
  end

  test "the standing: read is 403, none is 404, a full entry may change it, and the refusals map by name" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, access_default: "read")

    put access_path(conversation), headers: auth(@curator_secret), as: :json,
      params: { access: { default: "none", entries: [entry(@curator, "full")] } }
    assert_response :forbidden, "a read principal cannot escalate itself"
    assert_equal "not_authorized", error_code
    assert_equal "read", conversation.reload.access_default

    conversation.conversation_access_entries.create!(user: @curator, level: "full")
    put access_path(conversation), headers: auth(@curator_secret), as: :json,
      params: { access: { default: "none", entries: [entry(@curator, "full"), entry(@owner, "read")] } }
    assert_response :success, "full on the row is the standing, whoever holds it"
    assert_equal "none", conversation.reload.access_default

    put access_path(conversation), headers: auth, as: :json,
      params: { access: { default: "none", entries: [entry(@human, "read")] } }
    assert_response :unprocessable_entity
    assert_equal "principal_not_eligible", error_code, "the creator as an entry"

    put access_path(conversation), headers: auth, as: :json, params: { access: { default: "owner" } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", error_code

    put access_path(conversation), headers: auth, as: :json, params: { access: {} }
    assert_response :bad_request
    assert_equal "parameter_missing", error_code

    put access_path(conversation), headers: auth, as: :json, params: { access: { default: "none", entries: [] } }
    assert_response :success
    assert_equal "none", conversation.reload.access_default
    put access_path(conversation), headers: auth(@curator_secret), as: :json, params: { access: { default: "full" } }
    assert_response :not_found, "none conceals the door itself"
    assert_equal "none", conversation.reload.access_default
  end
end
