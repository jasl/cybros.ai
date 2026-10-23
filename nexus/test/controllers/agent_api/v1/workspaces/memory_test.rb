require "test_helper"

# Workspace collection content uses existing standing without a Conversation.
class AgentAPI::V1::Workspaces::MemoryTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
    @owner_secret = create_access_token_fixture(user: users(:owner), name: "Owner").secret
    @collection = MemoryCollection.default_for(@workspace)
  end

  def delete_fields(path)
    { path: path, **memory_conditions(@collection.memory_documents.find_by(name: path)) }
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def base = "/agent_api/v1/memory_collections/#{@collection.public_id}/documents"

  test "a workspace row lands without a conversation, and a conversation of the room reads it" do
    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the plan" } }
    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal ["notes.md", "the plan", 8], document.values_at("path", "content", "bytesize")
    row = @workspace.memory_documents.find_by!(name: "notes.md")
    assert_nil row.memory_collection.conversation_id, "the room's row, no conversation's"

    get base, headers: bearer(@owner_secret)
    assert_response :success
    assert_equal ["notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }

    post "#{base}/show", headers: bearer(@owner_secret), as: :json, params: { memory: { path: "notes.md" } }
    assert_response :success
    assert_equal "the plan", response.parsed_body.dig("memory", "content")

    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    get "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{conversation.public_id}/memory",
      headers: bearer(@secret)
    assert_response :success
    assert_equal ["workspace/notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") },
      "the conversation door lists the room's row the workspace door wrote"
  end

  test "relative names stay inside the addressed collection and malformed names are refused" do
    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :created
    assert_equal @collection.public_id, response.parsed_body.dig("memory", "collection_public_id")
    assert_empty @human.memory_documents
    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "../notes.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "memory_path_invalid", response.parsed_body.dig("error", "code")
    get base, headers: bearer(@secret)
    assert_response :success
    assert_equal ["user/notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }
  end

  test "delete is 204, and a repeated condition is stale" do
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "gone.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :created

    observed = delete_fields("gone.md")
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: observed }
    assert_response :no_content
    assert_not @workspace.memory_documents.exists?(name: "gone.md")

    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: observed }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  # WRITE STANDING IS THE WORKSPACE'S: an archived room still reads and
  # never writes (403 `not_authorized`, the plane's word); a caller with no
  # access finds no workspace at all.
  test "an archived room reads and never writes; a stranger finds no workspace" do
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "w" } }
    assert_response :created

    @workspace.update!(state: "archived", archived_at: Time.current)
    get base, headers: bearer(@secret)
    assert_response :success
    assert_equal ["notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }

    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "changed" } }
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("notes.md") }
    assert_response :forbidden
    assert_equal 1, @workspace.memory_documents.count, "nothing was written or deleted"

    private_room = workspaces(:personal)
    get "/agent_api/v1/memory_collections/#{MemoryCollection.default_for(private_room).public_id}/documents", headers: bearer(@secret)
    assert_response :not_found
  end

  # THE ONE GUARD: under an override every plain verb is 409 `memory_overridden` naming the provider
  # — the same guard the conversation door runs — and a `skills/` path still passes it.
  test "under an override every plain verb is 409 memory_overridden, and a skills/ path still passes" do
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "w" } }
    assert_response :created
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    assert_equal :updated, Workspaces::SetToolProviderOverrides.call(
      workspace: @workspace, by: users(:owner), lock_version: @workspace.reload.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    ).outcome

    get base, headers: bearer(@secret)
    assert_response :conflict
    assert_equal "memory_overridden", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "Provider mem"
    post "#{base}/show", headers: bearer(@secret), as: :json, params: { memory: { path: "notes.md" } }
    assert_response :conflict
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "changed" } }
    assert_response :conflict
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("notes.md") }
    assert_response :conflict
    assert_equal "w", @workspace.memory_documents.find_by!(name: "notes.md").content

    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "skills/commit-style", expected_public_id: nil, expected_lock_version: nil, content: "# Commits\n", description: "How commits are written." } }
    assert_response :created
    post "#{base}/show", headers: bearer(@secret), as: :json, params: { memory: { path: "skills/commit-style" } }
    assert_response :success
    assert_equal "How commits are written.", response.parsed_body.dig("memory", "description")
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("skills/commit-style") }
    assert_response :no_content
  end

  test "a transport credential is fenced with 401 — this is the member plane" do
    connection = connect_agent_session(steward: users(:owner), agent_identifier: users(:agent).agent_identifier)
    get base, headers: bearer(connection.executor_access_secret)
    assert_response :unauthorized
  end
end
