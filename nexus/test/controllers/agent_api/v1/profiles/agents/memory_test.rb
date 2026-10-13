require "test_helper"

# A NAMED DEFINITION'S OWN MEMORY: the declarer that minted a row reads and writes the `agent/`
# rung that row carries into every conversation it answers. The rung is the row's, not the
# steward's and not a sibling's; a Human is refused as the definitions door refuses it, and a name
# the caller did not mint is not found. The paired program's OWN `agent/` rung rides the profile
# memory door under the same prefix.
class AgentAPI::V1::Profiles::Agents::MemoryTest < ActionDispatch::IntegrationTest
  include RunLaneTestHelper

  setup do
    @owner = users(:owner)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @agent_secret = connect_agent_session(steward: @owner, agent_identifier: @agent.agent_identifier).access_secret
    @steward_secret = create_access_token_fixture(user: @owner, name: "S").secret
    @sibling_secret = connect_agent_session(steward: @owner, agent_identifier: "rho.sibling", display_name: "Sibling")
      .access_secret
    declare!("reviewer", scope: "steward")
    @reviewer = User.find_by!(agent_identifier: "#{@agent.agent_identifier}/reviewer")
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def door = "/agent_api/v1/profile/agents/reviewer/memory"
  def code = response.parsed_body.dig("error", "code")

  def declare!(name, scope:)
    put "/agent_api/v1/profile/agents/#{name}", headers: bearer(@agent_secret), as: :json,
      params: { scope: scope, description: "Reviews a diff for defects.", system_prompt: "You review.",
                configuration: { tool_definitions: [READ_TOOL], approval_mode: "bypass", approval_rules: nil,
                                 prompt_mechanism: "default", prompt_template: nil,
                                 compaction_policy: { mode: "kernel" }, default_model: nil, fallback_models: nil } }
    assert_response :created
  end

  def write!(path, content, secret: @agent_secret, at: door)
    post at, headers: bearer(secret), as: :json,
      params: { memory: { path: path, content: content, expected_public_id: nil, expected_lock_version: nil } }
  end

  test "the declarer writes the named row's agent/ rung, and it anchors on that row alone" do
    write!("agent/notes.md", "customers prefer short answers")

    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal "agent/notes.md", document.fetch("path")
    assert MemoryDocument.for_user(@reviewer.id).exists?(name: "notes.md"), "anchored on the named row"
    assert_not MemoryDocument.for_user(@owner.id).exists?(name: "notes.md"), "never the steward's user/ rung"
    assert_not MemoryDocument.for_user(@agent.id).exists?(name: "notes.md"), "never the declarer's own rung"

    get door, headers: bearer(@agent_secret)
    assert_response :success
    assert_equal ["agent/notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }

    post "#{door}/show", headers: bearer(@agent_secret), as: :json, params: { memory: { path: "agent/notes.md" } }
    assert_response :success
    assert_equal "customers prefer short answers", response.parsed_body.dig("memory", "content")

    post "#{door}/grep", headers: bearer(@agent_secret), as: :json, params: { memory: { pattern: "short" } }
    assert_response :success
    assert_equal ["agent/notes.md"], response.parsed_body.fetch("matches").map { |match| match.fetch("path") }
  end

  test "edit and delete take the observed version, as every memory door does" do
    write!("agent/notes.md", "first")
    document = response.parsed_body.fetch("memory")

    post "#{door}/edit", headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "agent/notes.md", old_text: "first", new_text: "second",
                          expected_public_id: document.fetch("public_id"),
                          expected_lock_version: document.fetch("lock_version") } }
    assert_response :success
    edited = response.parsed_body.fetch("memory")
    assert_equal "second", edited.fetch("content")
    assert_equal "agent/notes.md", edited.fetch("path")

    post "#{door}/delete", headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "agent/notes.md", expected_public_id: document.fetch("public_id"),
                          expected_lock_version: document.fetch("lock_version") } }
    assert_response :conflict
    assert_equal "stale_object", code

    post "#{door}/delete", headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "agent/notes.md", expected_public_id: edited.fetch("public_id"),
                          expected_lock_version: edited.fetch("lock_version") } }
    assert_response :no_content
    assert_not MemoryDocument.for_user(@reviewer.id).exists?
  end

  test "only agent/ resolves here; the other scopes have their own doors" do
    %w[user/notes.md workspace/notes.md conversation/notes.md speaker/notes.md].each do |path|
      write!(path, "x")
      assert_response :unprocessable_content, path
      assert_equal "memory_scope_unavailable", code, path
    end
    write!("notes.md", "x")
    assert_response :unprocessable_content
    assert_equal "memory_path_invalid", code
  end

  test "a sibling under the same steward and a Human are refused: the rung is the declarer's to manage" do
    write!("agent/notes.md", "x", secret: @sibling_secret)
    assert_response :not_found

    write!("agent/notes.md", "x", secret: @steward_secret)
    assert_response :forbidden
    assert_equal "not_agent", code

    get "/agent_api/v1/profile/agents/nobody/memory", headers: bearer(@agent_secret)
    assert_response :not_found
  end

  test "the paired program's own agent/ rung rides the profile memory door; a Human has none" do
    write!("agent/notes.md", "my own notes", at: "/agent_api/v1/profile/memory")
    assert_response :created
    assert MemoryDocument.for_user(@agent.id).exists?(name: "notes.md")
    assert_not MemoryDocument.for_user(@reviewer.id).exists?

    write!("user/plan.md", "the plan", at: "/agent_api/v1/profile/memory")
    assert_response :unprocessable_content
    assert_equal "memory_scope_unavailable", code
    assert_not MemoryDocument.for_user(@owner.id).exists?(name: "plan.md")

    write!("user/plan.md", "the plan", secret: @steward_secret, at: "/agent_api/v1/profile/memory")
    assert_response :created

    get "/agent_api/v1/profile/memory", headers: bearer(@agent_secret)
    assert_response :success
    assert_equal ["agent/notes.md"],
      response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }.sort

    get "/agent_api/v1/profile/memory", headers: bearer(@steward_secret)
    assert_response :success
    assert_equal ["user/plan.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") },
      "the steward reads its user/ notes and no agent's own rung"

    write!("agent/notes.md", "x", secret: @steward_secret, at: "/agent_api/v1/profile/memory")
    assert_response :unprocessable_content
    assert_equal "memory_scope_unavailable", code
  end
end
