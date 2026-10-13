require "test_helper"

# ONE STORE FAMILY OVER THREE HOSTS: Basic lists without values, Full singular responses, the
# opaque-value body exception including JSON null, receipt replay bound to the host, and every
# frozen mapping — on the workspace door as it always was, on the conversation door, and on the
# person's own door where no receipt is kept and a repeat is `key_taken`.
class AgentAPI::V1::StoreEntriesTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper

  setup do
    @member = create_access_token_fixture(user: users(:member), name: "Member")
    @shared = workspaces(:shared)
  end

  def conversation_entries_path(conversation, workspace: @shared)
    agent_api_v1_workspace_conversation_store_entries_path(workspace.public_id, conversation.public_id)
  end

  def conversation_entry_path(conversation, entry, workspace: @shared)
    agent_api_v1_workspace_conversation_store_entry_path(
      workspace.public_id, conversation.public_id, entry.public_id
    )
  end

  def with_key(headers, key = SecureRandom.uuid) = headers.merge("Idempotency-Key" => key)

  test "lists are Basic, namespace-key ordered, and composite-cursor paginated" do
    @shared.store_entries.create!(namespace: "b", key: "one", value: 1)
    @shared.store_entries.create!(namespace: "a", key: "two", value: { "deep" => true })
    @shared.store_entries.create!(namespace: "a", key: "one")

    get agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member), params: { limit: 2 }

    assert_response :success
    body = response.parsed_body
    assert_equal [%w[a one], %w[a two]], body["store_entries"].map { |e| [e["namespace"], e["key"]] }
    assert_not body["store_entries"].first.key?("value"), "lists are Basic"

    get agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member), params: { after: body.dig("pagination", "next_after") }
    assert_response :success
    rest = response.parsed_body
    assert_equal [%w[b one]], rest["store_entries"].map { |e| [e["namespace"], e["key"]] }
    assert_nil rest.dig("pagination", "next_after")
  end

  test "show is Full and a stored JSON null renders as null" do
    entry = @shared.store_entries.create!(namespace: "notes", key: "null", value: nil)

    get agent_api_v1_workspace_store_entry_path(@shared.public_id, entry.public_id),
      headers: bearer(@member)

    assert_response :success
    body = response.parsed_body["store_entry"]
    assert body.key?("value")
    assert_nil body["value"]
  end

  test "create stores any JSON value with receipt replay and digest mismatch" do
    key = SecureRandom.uuid
    payload = { store_entry: { namespace: "notes", key: "doc", value: { "nested" => [1, nil, "x"] } } }

    assert_difference -> { @shared.store_entries.count }, +1 do
      post agent_api_v1_workspace_store_entries_path(@shared.public_id),
        headers: bearer(@member).merge("Idempotency-Key" => key), params: payload, as: :json
    end
    assert_response :created
    created = response.parsed_body["store_entry"]
    assert_equal({ "nested" => [1, nil, "x"] }, created["value"])

    assert_no_difference -> { @shared.store_entries.count } do
      post agent_api_v1_workspace_store_entries_path(@shared.public_id),
        headers: bearer(@member).merge("Idempotency-Key" => key), params: payload, as: :json
    end
    assert_response :created
    assert_equal created["public_id"], response.parsed_body.dig("store_entry", "public_id")

    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => key),
      params: { store_entry: { namespace: "notes", key: "doc", value: "different" } }, as: :json
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "application state snapshots survive full response receipts and replay" do
    key = SecureRandom.uuid
    value = { "receipts" => "x" * 300_000 }
    payload = { store_entry: { namespace: "agent.channel", key: "state", value: value } }
    2.times do
      post agent_api_v1_workspace_store_entries_path(@shared.public_id),
        headers: bearer(@member).merge("Idempotency-Key" => key), params: payload, as: :json
      assert_response :created
      assert_equal value, response.parsed_body.dig("store_entry", "value")
    end
    assert_equal 1, @shared.store_entries.where(namespace: "agent.channel", key: "state").count
  end

  test "idempotent create digests persisted namespace and key representations" do
    idempotency_key = SecureRandom.uuid

    assert_difference -> { @shared.store_entries.count }, +1 do
      post agent_api_v1_workspace_store_entries_path(@shared.public_id),
        headers: bearer(@member).merge("Idempotency-Key" => idempotency_key),
        params: { store_entry: { namespace: 123, key: 456, value: "same" } },
        as: :json
    end
    assert_response :created
    created = response.parsed_body.fetch("store_entry")
    assert_equal "123", created.fetch("namespace")
    assert_equal "456", created.fetch("key")

    assert_no_difference -> { @shared.store_entries.count } do
      post agent_api_v1_workspace_store_entries_path(@shared.public_id),
        headers: bearer(@member).merge("Idempotency-Key" => idempotency_key),
        params: { store_entry: { namespace: "123", key: "456", value: "same" } },
        as: :json
    end
    assert_response :created
    assert_equal created.fetch("public_id"), response.parsed_body.dig("store_entry", "public_id")
  end

  test "create distinguishes explicit null from a missing value" do
    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "notes", key: "null", value: nil } }, as: :json
    assert_response :created
    assert_nil @shared.store_entries.find_by!(namespace: "notes", key: "null").value

    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "notes", key: "absent" } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "a scalar store_entry root is a missing root, 400" do
    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: "x" }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "missing coordinates are required-field 400s, never a 500" do
    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { key: "orphan", value: 1 } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "notes", value: 1 } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "duplicate keys, the cap, and oversize values map their frozen rows" do
    @shared.store_entries.create!(namespace: "notes", key: "taken")

    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "notes", key: "taken", value: 1 } }, as: :json
    assert_response :conflict
    assert_equal "key_taken", response.parsed_body.dig("error", "code")

    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "big", key: "v", value: "a" * Nexus::SizeBounds.fetch(:snapshot_bound) } }, as: :json
    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")

    62.times { |n| @shared.store_entries.create!(namespace: "bulk", key: "k#{n}") }
    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "bulk", key: "at-cap", value: 1 } }, as: :json
    assert_response :created

    post agent_api_v1_workspace_store_entries_path(@shared.public_id),
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "bulk", key: "over", value: 1 } }, as: :json
    assert_response :conflict
    assert_equal "entry_limit_reached", response.parsed_body.dig("error", "code")
  end

  test "writes are fenced for a mismatched Agent while reads pass" do
    dedicated = workspaces(:dedicated)
    entry = dedicated.store_entries.create!(namespace: "notes", key: "pinned", value: 1)
    mismatched_secret = connect_agent_session(
      steward: users(:owner), agent_identifier: "api-store-mismatch"
    ).access_secret

    get agent_api_v1_workspace_store_entry_path(dedicated.public_id, entry.public_id),
      headers: bearer_secret(mismatched_secret)
    assert_response :success

    post agent_api_v1_workspace_store_entries_path(dedicated.public_id),
      headers: bearer_secret(mismatched_secret).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { store_entry: { namespace: "notes", key: "mine", value: 1 } }, as: :json
    assert_response :forbidden
    assert_equal "workspace_agent_identifier_mismatch", response.parsed_body.dig("error", "code")

    patch agent_api_v1_workspace_store_entry_path(dedicated.public_id, entry.public_id),
      headers: bearer_secret(mismatched_secret),
      params: { store_entry: { value: 2, lock_version: entry.lock_version } }, as: :json
    assert_response :forbidden
  end

  test "an archived parent accepts reads but not writes" do
    entry = @shared.store_entries.create!(namespace: "notes", key: "pinned", value: 1)
    @shared.update_columns(state: "archived", archived_at: Time.current)

    get agent_api_v1_workspace_store_entry_path(@shared.public_id, entry.public_id),
      headers: bearer(@member)
    assert_response :success

    patch agent_api_v1_workspace_store_entry_path(@shared.public_id, entry.public_id),
      headers: bearer(@member),
      params: { store_entry: { value: 2, lock_version: entry.lock_version } }, as: :json
    assert_response :conflict
    assert_equal "workspace_not_active", response.parsed_body.dig("error", "code")
  end

  test "update replaces optimistically and stale writers lose" do
    entry = @shared.store_entries.create!(namespace: "notes", key: "pinned", value: { "v" => 1 })

    patch agent_api_v1_workspace_store_entry_path(@shared.public_id, entry.public_id),
      headers: bearer(@member),
      params: { store_entry: { value: nil, lock_version: entry.lock_version } }, as: :json
    assert_response :success
    assert_nil entry.reload.value

    patch agent_api_v1_workspace_store_entry_path(@shared.public_id, entry.public_id),
      headers: bearer(@member),
      params: { store_entry: { value: 3, lock_version: 0 } }, as: :json
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  test "delete is 204 with a required query lock_version" do
    entry = @shared.store_entries.create!(namespace: "notes", key: "gone")

    delete agent_api_v1_workspace_store_entry_path(@shared.public_id, entry.public_id),
      headers: bearer(@member)
    assert_response :bad_request

    delete agent_api_v1_workspace_store_entry_path(@shared.public_id, entry.public_id),
      headers: bearer(@member), params: { lock_version: entry.lock_version }
    assert_response :no_content
    assert_nil StoreEntry.find_by(id: entry.id)
  end

  test "wrong parents and inaccessible parents conceal entries as 404" do
    entry = @shared.store_entries.create!(namespace: "notes", key: "pinned")

    get agent_api_v1_workspace_store_entry_path(workspaces(:dedicated).public_id, entry.public_id),
      headers: bearer(@member)
    assert_response :not_found

    get agent_api_v1_workspace_store_entries_path(workspaces(:personal).public_id),
      headers: bearer(@member)
    assert_response :not_found
  end

  # ── The conversation host ─────────────────────────────────────────────────

  test "the conversation door lists, shows, creates, updates and deletes its own rows only" do
    conversation = Conversation.create!(workspace: @shared, creating_user: users(:member))
    @shared.store_entries.create!(namespace: "notes", key: "room")

    post conversation_entries_path(conversation), headers: with_key(bearer(@member)),
      params: { store_entry: { namespace: "notes", key: "pinned", value: { "v" => 1 } } }, as: :json
    assert_response :created
    created = response.parsed_body.fetch("store_entry")
    entry = StoreEntry.find_by!(public_id: created.fetch("public_id"))
    assert_equal conversation, entry.host
    assert_nil entry.workspace_id

    get conversation_entries_path(conversation), headers: bearer(@member)
    assert_response :success
    assert_equal %w[pinned], response.parsed_body["store_entries"].map { |row| row["key"] }
    get agent_api_v1_workspace_store_entries_path(@shared.public_id), headers: bearer(@member)
    assert_equal %w[room], response.parsed_body["store_entries"].map { |row| row["key"] },
      "a conversation's row is absent from its workspace's store"

    get conversation_entry_path(conversation, entry), headers: bearer(@member)
    assert_response :success
    assert_equal({ "v" => 1 }, response.parsed_body.dig("store_entry", "value"))

    patch conversation_entry_path(conversation, entry), headers: bearer(@member),
      params: { store_entry: { value: 2, lock_version: entry.lock_version } }, as: :json
    assert_response :success
    assert_equal 2, entry.reload.value

    delete conversation_entry_path(conversation, entry), headers: bearer(@member),
      params: { lock_version: entry.lock_version }
    assert_response :no_content
    assert_nil StoreEntry.find_by(id: entry.id)
  end

  test "a conversation create replays through conversation_command_receipts, scoped to its conversation" do
    conversation = Conversation.create!(workspace: @shared, creating_user: users(:member))
    sibling = Conversation.create!(workspace: @shared, creating_user: users(:member))
    key = SecureRandom.uuid
    payload = { store_entry: { namespace: "notes", key: "doc", value: [1, nil] } }

    assert_difference -> { conversation.store_entries.count }, +1 do
      post conversation_entries_path(conversation), headers: with_key(bearer(@member), key),
        params: payload, as: :json
    end
    assert_response :created
    created = response.parsed_body.fetch("store_entry")

    assert_no_difference -> { StoreEntry.count } do
      post conversation_entries_path(conversation), headers: with_key(bearer(@member), key),
        params: payload, as: :json
    end
    assert_response :created
    assert_equal created.fetch("public_id"), response.parsed_body.dig("store_entry", "public_id")
    assert_equal 1,
      ConversationCommandReceipt.where(operation: "store_entry_create", host: conversation).count
    assert_equal 0, WorkspaceCommandReceipt.where(operation: "store_entry_create").count

    post conversation_entries_path(conversation), headers: with_key(bearer(@member), key),
      params: { store_entry: { namespace: "notes", key: "doc", value: "other" } }, as: :json
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")

    # The same key on a second conversation is a second row, never a replay.
    assert_difference -> { sibling.store_entries.count }, +1 do
      post conversation_entries_path(sibling), headers: with_key(bearer(@member), key),
        params: payload, as: :json
    end
    assert_response :created
    assert_not_equal created.fetch("public_id"), response.parsed_body.dig("store_entry", "public_id")
  end

  test "the conversation door is fenced for a mismatched Agent, read-only when archived, absent when tombstoned" do
    dedicated = workspaces(:dedicated)
    conversation = Conversation.create!(workspace: dedicated, creating_user: users(:agent))
    entry = conversation.store_entries.create!(namespace: "notes", key: "pinned", value: 1)
    mismatched_secret = connect_agent_session(
      steward: users(:owner), agent_identifier: "api-conv-store-mismatch"
    ).access_secret

    get conversation_entries_path(conversation, workspace: dedicated),
      headers: bearer_secret(mismatched_secret)
    assert_response :success

    post conversation_entries_path(conversation, workspace: dedicated),
      headers: with_key(bearer_secret(mismatched_secret)),
      params: { store_entry: { namespace: "notes", key: "mine", value: 1 } }, as: :json
    assert_response :forbidden
    assert_equal "workspace_agent_identifier_mismatch", response.parsed_body.dig("error", "code")

    owner = create_access_token_fixture(user: users(:owner), name: "Owner")
    conversation.update_columns(archived_at: Time.current)
    get conversation_entry_path(conversation, entry, workspace: dedicated), headers: bearer(owner)
    assert_response :success
    post conversation_entries_path(conversation, workspace: dedicated),
      headers: with_key(bearer(owner)),
      params: { store_entry: { namespace: "notes", key: "later", value: 1 } }, as: :json
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")
    patch conversation_entry_path(conversation, entry, workspace: dedicated), headers: bearer(owner),
      params: { store_entry: { value: 2, lock_version: entry.lock_version } }, as: :json
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")

    conversation.update_columns(tombstoned_at: Time.current)
    get conversation_entries_path(conversation, workspace: dedicated), headers: bearer(owner)
    assert_response :not_found
    post conversation_entries_path(conversation, workspace: dedicated),
      headers: with_key(bearer(owner)),
      params: { store_entry: { namespace: "notes", key: "gone", value: 1 } }, as: :json
    assert_response :not_found
  end

  # ── The profile host: the ACTING principal's own row ───────

  def profile_setup
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @agent_secret = connection.access_secret
    @transport_secret = connection.executor_access_secret
    @steward = create_access_token_fixture(user: users(:owner), name: "Steward")
  end

  test "an agent's profile store is the agent's own, invisible to its steward" do
    profile_setup

    post agent_api_v1_profile_store_entries_path, headers: with_key(bearer_secret(@agent_secret)),
      params: { store_entry: { namespace: "ui", key: "own", value: { "tab" => 1 } } }, as: :json
    assert_response :created
    created = response.parsed_body.fetch("store_entry")
    assert_equal({ "tab" => 1 }, created.fetch("value"))
    assert_equal 1, StoreEntry.for_user(@agent.id).count
    assert_equal 0, StoreEntry.for_user(users(:owner).id).count

    get agent_api_v1_profile_store_entries_path, headers: bearer_secret(@agent_secret)
    assert_response :success
    assert_equal %w[own], response.parsed_body["store_entries"].map { |row| row["key"] }

    get agent_api_v1_profile_store_entries_path, headers: bearer(@steward)
    assert_response :success
    assert_empty response.parsed_body["store_entries"], "the steward's store is the steward's"

    get agent_api_v1_profile_store_entry_path(created.fetch("public_id")), headers: bearer(@steward)
    assert_response :not_found

    get agent_api_v1_profile_store_entries_path, headers: bearer_secret(@transport_secret)
    assert_response :unauthorized
  end

  test "a retried profile create is key_taken — no receipt, no replay — and the header stays required" do
    profile_setup
    key = SecureRandom.uuid
    payload = { store_entry: { namespace: "ui", key: "own", value: 1 } }

    post agent_api_v1_profile_store_entries_path, headers: with_key(bearer_secret(@agent_secret), key),
      params: payload, as: :json
    assert_response :created

    assert_no_difference [-> { WorkspaceCommandReceipt.count }, -> { ConversationCommandReceipt.count }] do
      post agent_api_v1_profile_store_entries_path, headers: with_key(bearer_secret(@agent_secret), key),
        params: payload, as: :json
    end
    assert_response :conflict
    assert_equal "key_taken", response.parsed_body.dig("error", "code")
    assert_equal 1, StoreEntry.for_user(@agent.id).count

    post agent_api_v1_profile_store_entries_path, headers: bearer_secret(@agent_secret),
      params: { store_entry: { namespace: "ui", key: "other", value: 1 } }, as: :json
    assert_response :bad_request
    assert_equal "idempotency_key_required", response.parsed_body.dig("error", "code")
  end

  test "the profile door updates and deletes under the CAS and caps at 64" do
    profile_setup
    entry = @agent.store_entries.create!(namespace: "ui", key: "own", value: 1)

    patch agent_api_v1_profile_store_entry_path(entry.public_id), headers: bearer_secret(@agent_secret),
      params: { store_entry: { value: 2, lock_version: entry.lock_version } }, as: :json
    assert_response :success
    assert_equal 2, entry.reload.value

    patch agent_api_v1_profile_store_entry_path(entry.public_id), headers: bearer_secret(@agent_secret),
      params: { store_entry: { value: 3, lock_version: 0 } }, as: :json
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")

    delete agent_api_v1_profile_store_entry_path(entry.public_id), headers: bearer_secret(@agent_secret),
      params: { lock_version: entry.lock_version }
    assert_response :no_content
    assert_nil StoreEntry.find_by(id: entry.id)

    StoreEntry::MAX_ENTRIES_PER_HOST.times { |n| @agent.store_entries.create!(namespace: "bulk", key: "k#{n}") }
    post agent_api_v1_profile_store_entries_path, headers: with_key(bearer_secret(@agent_secret)),
      params: { store_entry: { namespace: "bulk", key: "over", value: 1 } }, as: :json
    assert_response :conflict
    assert_equal "entry_limit_reached", response.parsed_body.dig("error", "code")
  end

  private

    def bearer(fixture)
      { "Authorization" => "Bearer #{fixture.secret}" }
    end

    def bearer_secret(secret)
      { "Authorization" => "Bearer #{secret}" }
    end
end
