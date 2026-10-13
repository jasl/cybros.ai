require "test_helper"

# THE ROOM'S OWN DOOR to memory's `workspace/` scope (audit
# alt-silent-losses-5): a workspace row is written and read here without
# picking a conversation of the room; every conversation's next turn reads
# it live. Only `workspace/` resolves; the other two scopes have their own
# doors. Write standing is the workspace's; the override guard is the one
# the conversation door shares.
class AgentAPI::V1::Workspaces::MemoryTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
    @owner_secret = create_access_token_fixture(user: users(:owner), name: "Owner").secret
  end

  def delete_fields(path)
    anchor = Scopes::Anchor.call(path: path, workspace: @workspace)
    { path: path, **memory_conditions(anchor.documents.find_by(name: anchor.name)) }
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def base = "/agent_api/v1/workspaces/#{@workspace.public_id}/memory"

  test "a workspace row lands without a conversation, and a conversation of the room reads it" do
    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the plan" } }
    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal ["workspace/notes.md", "the plan", 8], document.values_at("path", "content", "bytesize")
    row = MemoryDocument.for_workspace(@workspace.id).find_by!(name: "notes.md")
    assert_nil row.conversation_id, "the room's row, no conversation's"

    get base, headers: bearer(@owner_secret)
    assert_response :success
    assert_equal ["workspace/notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }

    post "#{base}/show", headers: bearer(@owner_secret), as: :json, params: { memory: { path: "workspace/notes.md" } }
    assert_response :success
    assert_equal "the plan", response.parsed_body.dig("memory", "content")

    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    get "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{conversation.public_id}/memory",
      headers: bearer(@secret)
    assert_response :success
    assert_equal ["workspace/notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") },
      "the conversation door lists the room's row the workspace door wrote"
  end

  test "only workspace/ resolves at this door; the other scopes and a bare name are refused" do
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")

    post "#{base}/show", headers: bearer(@secret), as: :json, params: { memory: { path: "conversation/plan.md" } }
    assert_response :unprocessable_content
    assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")

    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "memory_path_invalid", response.parsed_body.dig("error", "code")

    get base, headers: bearer(@secret)
    assert_response :success
    assert_empty response.parsed_body.fetch("memory"), "the listing is the room's rows alone"
  end

  test "delete is 204, and a repeated condition is stale" do
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/gone.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :created

    observed = delete_fields("workspace/gone.md")
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: observed }
    assert_response :no_content
    assert_not MemoryDocument.for_workspace(@workspace.id).exists?(name: "gone.md")

    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: observed }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  # WRITE STANDING IS THE WORKSPACE'S: an archived room still reads and
  # never writes (403 `not_authorized`, the plane's word); a caller with no
  # access finds no workspace at all.
  test "an archived room reads and never writes; a stranger finds no workspace" do
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "w" } }
    assert_response :created

    @workspace.update!(state: "archived", archived_at: Time.current)
    get base, headers: bearer(@secret)
    assert_response :success
    assert_equal ["workspace/notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }

    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "changed" } }
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("workspace/notes.md") }
    assert_response :forbidden
    assert_equal 1, MemoryDocument.for_workspace(@workspace.id).count, "nothing was written or deleted"

    private_room = workspaces(:personal)
    get "/agent_api/v1/workspaces/#{private_room.public_id}/memory", headers: bearer(@secret)
    assert_response :not_found
  end

  # THE ONE GUARD: under an override every plain verb is 409 `memory_overridden` naming the provider
  # — the same guard the conversation door runs — and a `skills/` path still passes it.
  test "under an override every plain verb is 409 memory_overridden, and a skills/ path still passes" do
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "w" } }
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
    post "#{base}/show", headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/notes.md" } }
    assert_response :conflict
    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "changed" } }
    assert_response :conflict
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("workspace/notes.md") }
    assert_response :conflict
    assert_equal "w", MemoryDocument.for_workspace(@workspace.id).find_by!(name: "notes.md").content

    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "workspace/skills/commit-style", expected_public_id: nil, expected_lock_version: nil, content: "# Commits\n", description: "How commits are written." } }
    assert_response :created
    post "#{base}/show", headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/skills/commit-style" } }
    assert_response :success
    assert_equal "How commits are written.", response.parsed_body.dig("memory", "description")
    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("workspace/skills/commit-style") }
    assert_response :no_content
  end

  test "a transport credential is fenced with 401 — this is the member plane" do
    connection = connect_agent_session(steward: users(:owner), agent_identifier: users(:agent).agent_identifier)
    get base, headers: bearer(connection.executor_access_secret)
    assert_response :unauthorized
  end
end
