require "test_helper"

# THE CONVERSATION DOOR over three scopes: its listing is the same three the assembly block reads
# for the turn THIS caller would post — the conversation's own, its workspace's, and the caller's
# controlling Human's `user/`; another Human's `user/` rows are absent. Writes pass the caller, so
# `user/…` lands under the caller's Human.
class AgentAPI::V1::Workspaces::Conversations::MemoryTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
    @owner_secret = create_access_token_fixture(user: users(:owner), name: "Owner").secret
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def delete_fields(path)
    anchor = Scopes::Anchor.call(path: path, workspace: @workspace, conversation: @conversation, user: @human)
    { path: path, **memory_conditions(anchor.documents.find_by(name: anchor.name)) }
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def base = "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/memory"

  def write!(path, content, by: @human)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: by),
      conversation: @conversation, path: path, content: content, by: by
    )
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  test "index lists the three scopes for the caller, and never another Human's user/" do
    write!("conversation/plan.md", "c")
    write!("workspace/shared.md", "w")
    write!("user/mine.md", "u")
    write!("user/theirs.md", "t", by: users(:owner))

    get base, headers: bearer(@secret)
    assert_response :success
    assert_equal %w[conversation/plan.md user/mine.md workspace/shared.md],
      response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }

    get base, headers: bearer(@owner_secret)
    assert_response :success
    assert_equal %w[conversation/plan.md user/theirs.md workspace/shared.md],
      response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }
  end

  test "create user/ lands under the caller's controlling Human, and show reads it back" do
    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "mine" } }
    assert_response :created
    assert_equal "user/notes.md", response.parsed_body.dig("memory", "path")
    assert MemoryDocument.for_user(@human.id).exists?(name: "notes.md")
    assert_not MemoryDocument.for_conversation(@conversation.id).exists?

    post "#{base}/show", headers: bearer(@secret), as: :json,
      params: { memory: { path: "user/notes.md" } }
    assert_response :success
    assert_equal "mine", response.parsed_body.dig("memory", "content")

    post "#{base}/show", headers: bearer(@owner_secret), as: :json,
      params: { memory: { path: "user/notes.md" } }
    assert_response :not_found, "the same path names the OTHER caller's scope"
  end

  test "a browsable-but-not-writable caller reads and never writes" do
    agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: agent.agent_identifier)
    # Creation-frozen, so the row is dedicated to another program directly.
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "some-other-program")

    get base, headers: bearer(connection.access_secret)
    assert_response :success

    post base, headers: bearer(connection.access_secret), as: :json,
      params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  end

  test "an archived conversation refuses writes with 409" do
    write!("workspace/notes.md", "x")
    Conversations::Archive.call(conversation: @conversation)

    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "y" } }
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")
  end

  # WHILE THE WORKSPACE IS OVERRIDDEN: the whole door is 409 `memory_overridden` naming the provider
  # — reads and writes, the `user/` rung included (the person's own door keeps serving that one).
  # The rows written before wait untouched for the override to clear.
  test "under an override every verb is 409 memory_overridden naming the provider" do
    write!("workspace/notes.md", "w")
    write!("user/mine.md", "u")
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    set = ->(overrides) {
      Workspaces::SetToolProviderOverrides.call(
        workspace: @workspace, by: users(:owner), lock_version: @workspace.reload.lock_version,
        overrides: overrides
      )
    }
    assert_equal :updated, set.call({ "nexus.memory" => provider.public_id }).outcome

    get base, headers: bearer(@secret)
    assert_response :conflict
    assert_equal "memory_overridden", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "Provider mem"

    post "#{base}/show", headers: bearer(@secret), as: :json, params: { memory: { path: "user/mine.md" } }
    assert_response :conflict
    assert_equal "memory_overridden", response.parsed_body.dig("error", "code")

    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "changed" } }
    assert_response :conflict
    assert_equal "memory_overridden", response.parsed_body.dig("error", "code")

    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("workspace/notes.md") }
    assert_response :conflict
    assert_equal "memory_overridden", response.parsed_body.dig("error", "code")
    assert_equal 2, MemoryDocument.count, "nothing was written or deleted"

    assert_equal :updated, set.call({}).outcome
    get base, headers: bearer(@secret)
    assert_response :success
    assert_equal %w[user/mine.md workspace/notes.md],
      response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }
  end

  # THE WORKSPACE RUNG'S SKILL DOOR: a `workspace/skills/<name>` row is written through any
  # conversation of the room, and `conversation/skills/…` is refused — a skill is never per
  # conversation.
  test "workspace/skills/<name> is written here with a description; conversation/skills is refused" do
    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "workspace/skills/commit-style", expected_public_id: nil, expected_lock_version: nil, content: "# Commits\n",
                          description: "How this team writes commit messages." } }
    assert_response :created
    assert_equal "How this team writes commit messages.", response.parsed_body.dig("memory", "description")
    assert MemoryDocument.for_workspace(@workspace.id).skills.exists?(name: "skills/commit-style")

    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "conversation/skills/plan", expected_public_id: nil, expected_lock_version: nil, content: "x", description: "d" } }
    assert_response :unprocessable_content
    assert_equal "skill_scope_unavailable", response.parsed_body.dig("error", "code")

    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "workspace/skills/commit-style", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "skill_description_required", response.parsed_body.dig("error", "code")
  end

  # SKILLS ARE INSTRUCTIONS, NOT MEMORY: a `skills/` row is never the provider's, so a verb naming
  # one passes the override guard while every plain path is still 409.
  test "under an override a skills/ path is still written, read and deleted here" do
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    assert_equal :updated, Workspaces::SetToolProviderOverrides.call(
      workspace: @workspace, by: users(:owner), lock_version: @workspace.reload.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    ).outcome

    post base, headers: bearer(@secret), as: :json,
      params: { memory: { path: "workspace/skills/commit-style", expected_public_id: nil, expected_lock_version: nil, content: "# Commits\n", description: "How." } }
    assert_response :created

    post "#{base}/show", headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/skills/commit-style" } }
    assert_response :success
    assert_equal "# Commits\n", response.parsed_body.dig("memory", "content")

    post base, headers: bearer(@secret), as: :json, params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "n" } }
    assert_response :conflict
    assert_equal "memory_overridden", response.parsed_body.dig("error", "code")
    get base, headers: bearer(@secret)
    assert_response :conflict

    post "#{base}/delete", headers: bearer(@secret), as: :json, params: { memory: delete_fields("workspace/skills/commit-style") }
    assert_response :no_content
    assert_not MemoryDocument.for_workspace(@workspace.id).skills.exists?
  end
end
