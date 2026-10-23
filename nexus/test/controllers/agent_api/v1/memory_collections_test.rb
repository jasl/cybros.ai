require "test_helper"

class AgentAPI::V1::MemoryCollectionsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:owner)
    @member = users(:member)
    @workspace = workspaces(:shared)
    @owner_secret = create_access_token_fixture(user: @owner, name: "Collections owner").secret
    @member_secret = create_access_token_fixture(user: @member, name: "Collections member").secret
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @member)
    MemoryCollection.default_for(@conversation)
  end

  test "read standing permits content writes but only the Workspace owner manages collections" do
    collection = create_collection
    post documents(collection), headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "notes.md", content: "shared", expected_public_id: nil, expected_lock_version: nil } }
    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal collection.fetch("public_id"), document.fetch("collection_public_id")
    assert_equal "notes.md", document.fetch("path")

    patch collection_path(collection), headers: bearer(@member_secret), as: :json,
      params: { memory_collection: { name: "Not mine", lock_version: collection.fetch("lock_version") } }
    assert_response :forbidden
    patch collection_path(collection), headers: bearer(@owner_secret), as: :json,
      params: { memory_collection: { name: "Renamed", lock_version: collection.fetch("lock_version") } }
    assert_response :success
    patch collection_path(collection), headers: bearer(@owner_secret), as: :json,
      params: { memory_collection: { name: "Stale", lock_version: collection.fetch("lock_version") } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  test "collection lifecycle is versioned and archived documents remain read only" do
    collection = create_collection
    post "#{collection_path(collection)}/archive", headers: bearer(@owner_secret), as: :json,
      params: { memory_collection: { lock_version: collection.fetch("lock_version") } }
    assert_response :success
    archived = response.parsed_body.fetch("memory_collection")
    post documents(collection), headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "notes.md", content: "late", expected_public_id: nil, expected_lock_version: nil } }
    assert_response :forbidden
    assert_equal "memory_read_only", response.parsed_body.dig("error", "code")
    post "#{collection_path(collection)}/restore", headers: bearer(@owner_secret), as: :json,
      params: { memory_collection: { lock_version: archived.fetch("lock_version") } }
    assert_response :success
    restored = response.parsed_body.fetch("memory_collection")
    assert_equal collection.fetch("public_id"), restored.fetch("public_id")
    delete collection_path(collection), headers: bearer(@owner_secret), as: :json,
      params: { memory_collection: { lock_version: restored.fetch("lock_version") } }
    assert_response :no_content
    get collection_path(collection), headers: bearer(@owner_secret)
    assert_response :not_found
  end

  test "a path rebound to another empty collection rejects the old create condition" do
    first = create_collection
    second = create_collection
    bind_collection(first)
    get conversation_memory, headers: bearer(@member_secret)
    assert_response :success
    binding = response.parsed_body.dig("memory_context", "bindings").find { |entry| entry.fetch("name") == "shared" }
    assert_equal first.fetch("public_id"), binding.fetch("collection_public_id")
    bind_collection(second)

    post conversation_memory, headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "shared/notes.md", content: "old proposal",
        expected_collection_public_id: first.fetch("public_id"), expected_public_id: nil, expected_lock_version: nil } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
    assert_not MemoryDocument.exists?(name: "notes.md")

    post conversation_memory, headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "shared/notes.md", content: "current proposal",
        expected_collection_public_id: second.fetch("public_id"), expected_public_id: nil, expected_lock_version: nil } }
    assert_response :created
    assert_equal second.fetch("public_id"), response.parsed_body.dig("memory", "collection_public_id")
  end

  test "list and point reads conceal another Human's private collections before pagination" do
    private_collection = MemoryCollection.create_for(@owner, name: "Private")
    get "/agent_api/v1/memory_collections", headers: bearer(@member_secret), params: { limit: 1 }
    assert_response :success
    seen = []
    loop do
      seen.concat(response.parsed_body.fetch("memory_collections").map { |row| row.fetch("public_id") })
      after = response.parsed_body.dig("pagination", "next_after")
      break unless after

      get "/agent_api/v1/memory_collections", headers: bearer(@member_secret), params: { limit: 1, after: after }
      assert_response :success
    end
    assert_equal seen.uniq, seen
    assert_not_includes seen, private_collection.public_id
    get "/agent_api/v1/memory_collections/#{private_collection.public_id}", headers: bearer(@member_secret)
    assert_response :not_found
  end

  test "default discovery is bounded to one owner and subject and never allocates or replaces a tombstone" do
    agent = users(:agent)
    secret = connect_agent_session(steward: @owner, agent_identifier: agent.agent_identifier).access_secret
    speaker = Speaker.register_ingress(user: agent, channel_key: "default-discovery", external_id: "one", display_name: "One")
    path = "/agent_api/v1/profile/memory_collections"
    assert_no_difference "MemoryCollection.count" do
      get path, headers: bearer(secret), params: { default: true, speaker_public_id: speaker.public_id }
      assert_response :success
      assert_empty response.parsed_body.fetch("memory_collections")
    end
    selected = MemoryCollection.default_for(agent, speaker: speaker)
    MemoryCollection.create_for(agent, speaker: speaker, name: "Other")
    get path, headers: bearer(secret), params: { default: true, speaker_public_id: speaker.public_id }
    assert_equal [selected.public_id], response.parsed_body.fetch("memory_collections").map { |row| row.fetch("public_id") }
    get path, headers: bearer(secret), params: { default: true }
    assert_equal [MemoryCollection.default_for(agent).public_id], response.parsed_body.fetch("memory_collections").map { |row| row.fetch("public_id") }

    selected.tombstone
    assert_no_difference "MemoryCollection.count" do
      get path, headers: bearer(secret), params: { default: true, speaker_public_id: speaker.public_id }
      assert_empty response.parsed_body.fetch("memory_collections")
      post path, headers: bearer(secret), as: :json, params: { memory_collection: { default: true, speaker_public_id: speaker.public_id } }
      assert_response :unprocessable_content
      assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")
    end
  end

  test "Agent Speaker and named Agent collections never grant access to a steward or sibling" do
    agent = users(:agent)
    secret = connect_agent_session(steward: @owner, agent_identifier: agent.agent_identifier).access_secret
    speaker = Speaker.register_ingress(user: agent, channel_key: "collection-test", external_id: "one", display_name: "One")
    other = Speaker.register_ingress(user: agent, channel_key: "collection-test", external_id: "two", display_name: "Two")
    assert_no_difference "MemoryCollection.count" do
      get "/agent_api/v1/profile/memory_collections", headers: bearer(secret)
      assert_response :success
    end
    post "/agent_api/v1/profile/memory_collections", headers: bearer(secret), as: :json,
      params: { memory_collection: { default: true, speaker_public_id: speaker.public_id } }
    assert_response :created
    selected = response.parsed_body.fetch("memory_collection")
    assert_equal "speaker", selected.fetch("scope")
    assert_equal agent.public_id, selected.fetch("owner_public_id")
    assert_equal speaker.public_id, selected.fetch("speaker_public_id")
    assert selected.fetch("is_default")
    post "/agent_api/v1/profile/memory_collections", headers: bearer(secret), as: :json,
      params: { memory_collection: { default: true, speaker_public_id: other.public_id } }
    assert_response :created
    assert_not_equal selected.fetch("public_id"), response.parsed_body.dig("memory_collection", "public_id")

    definition = agent.named_agents.create!(account: agent.account, kind: :agent, role: :member,
      steward: @owner, agent_identifier: "#{agent.agent_identifier}/notes", named_agent_scope: :steward,
      description: "Notes", display_name: "Notes")
    post "/agent_api/v1/profile/agents/notes/memory_collections", headers: bearer(secret), as: :json,
      params: { memory_collection: { name: "Private notes" } }
    assert_response :created
    named = response.parsed_body.fetch("memory_collection")
    assert_equal definition.public_id, named.fetch("owner_public_id")
    sibling = connect_agent_session(steward: @owner, agent_identifier: "collections.sibling").access_secret
    [@owner_secret, @member_secret, sibling].each do |denied|
      [selected, named].each do |collection|
        get collection_path(collection), headers: bearer(denied)
        assert_response :not_found
        get documents(collection), headers: bearer(denied)
        assert_response :not_found
      end
    end
    delete collection_path(selected), headers: bearer(secret), as: :json,
      params: { memory_collection: { lock_version: selected.fetch("lock_version") } }
    assert_response :no_content
    assert_no_difference "MemoryCollection.count" do
      post "/agent_api/v1/profile/memory_collections", headers: bearer(secret), as: :json,
        params: { memory_collection: { default: true, speaker_public_id: speaker.public_id } }
      assert_response :unprocessable_content
      assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")
    end
  end

  test "Conversation collection access follows full read and none independently of archive" do
    @conversation.update!(access_default: "read", archived_at: Time.current)
    collection = @conversation.memory_collections.find_by!(is_default: true)
    document_url = documents("public_id" => collection.public_id)
    get document_url, headers: bearer(@owner_secret)
    assert_response :success
    post document_url, headers: bearer(@owner_secret), as: :json,
      params: { memory: { path: "notes.md", content: "not allowed", expected_public_id: nil, expected_lock_version: nil } }
    assert_response :forbidden
    post document_url, headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "notes.md", content: "owner management", expected_public_id: nil, expected_lock_version: nil } }
    assert_response :created
    document = response.parsed_body.fetch("memory")
    post conversation_memory, headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "conversation/notes.md", content: "through host", expected_collection_public_id: collection.public_id,
        expected_public_id: document.fetch("public_id"), expected_lock_version: document.fetch("lock_version") } }
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")
    @conversation.update!(access_default: "none")
    get document_url, headers: bearer(@owner_secret)
    assert_response :not_found
    get "/agent_api/v1/memory_collections/#{collection.public_id}", headers: bearer(@owner_secret)
    assert_response :not_found
  end

  test "collection UUIDs do not bypass a memory provider but metadata and kernel skills remain available" do
    collection = create_collection
    provider = connect_provider(identifier: "collection-memory", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    Workspaces::SetToolProviderOverrides.call(workspace: @workspace, by: @owner,
      lock_version: @workspace.reload.lock_version, overrides: { "nexus.memory" => provider.public_id })
    get collection_path(collection), headers: bearer(@member_secret)
    assert_response :success
    get documents(collection), headers: bearer(@member_secret)
    assert_response :conflict
    assert_equal "memory_overridden", response.parsed_body.dig("error", "code")
    post documents(collection), headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "notes.md", content: "no bypass", expected_public_id: nil, expected_lock_version: nil } }
    assert_response :conflict
    post documents(collection), headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "skills/review", content: "Read first", description: "Review", expected_public_id: nil, expected_lock_version: nil } }
    assert_response :created
    post "#{documents(collection)}/show", headers: bearer(@member_secret), as: :json,
      params: { memory: { path: "skills/review" } }
    assert_response :success
    assert_equal "Read first", response.parsed_body.dig("memory", "content")
    bind_collection(collection, status: :unprocessable_content)
    assert_equal "memory_collection_provider_unsupported", response.parsed_body.dig("error", "code")
  end

  private

    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
    def collection_path(collection) = "/agent_api/v1/memory_collections/#{collection.fetch("public_id")}"
    def documents(collection) = "#{collection_path(collection)}/documents"
    def conversation_memory = "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/memory"

    def create_collection
      post "/agent_api/v1/workspaces/#{@workspace.public_id}/memory_collections", headers: bearer(@owner_secret), as: :json,
        params: { memory_collection: { name: "Shared notes", description: "Team facts" } }
      assert_response :created
      response.parsed_body.fetch("memory_collection")
    end

    def bind_collection(collection, status: :success)
      post "#{conversation_memory}_context", headers: bearer(@member_secret), as: :json,
        params: { memory_context: { bindings: [{ name: "shared", access: "read_write",
          source: { collection_public_id: collection.fetch("public_id") } }] } }
      assert_response status
    end
end
