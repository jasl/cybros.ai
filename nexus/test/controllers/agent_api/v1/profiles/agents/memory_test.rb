require "test_helper"

# Named Agent collections remain private to their declarer and Agent.
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
    @collection = MemoryCollection.default_for(@reviewer)
    @own_collection = MemoryCollection.default_for(@agent)
    @human_collection = MemoryCollection.default_for(@owner)
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def door(collection = @collection) = "/agent_api/v1/memory_collections/#{collection.public_id}/documents"
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
    write!("notes.md", "customers prefer short answers")

    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal "notes.md", document.fetch("path")
    assert @reviewer.memory_documents.exists?(name: "notes.md"), "anchored on the named row"
    assert_not @owner.memory_documents.exists?(name: "notes.md"), "never the steward's user/ rung"
    assert_not @agent.memory_documents.exists?(name: "notes.md"), "never the declarer's own rung"

    get door, headers: bearer(@agent_secret)
    assert_response :success
    assert_equal ["notes.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }

    post "#{door}/show", headers: bearer(@agent_secret), as: :json, params: { memory: { path: "notes.md" } }
    assert_response :success
    assert_equal "customers prefer short answers", response.parsed_body.dig("memory", "content")

    post "#{door}/grep", headers: bearer(@agent_secret), as: :json, params: { memory: { pattern: "short" } }
    assert_response :success
    assert_equal ["notes.md"], response.parsed_body.fetch("matches").map { |match| match.fetch("path") }
  end

  test "edit and delete take the observed version, as every memory door does" do
    write!("notes.md", "first")
    document = response.parsed_body.fetch("memory")

    post "#{door}/edit", headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "notes.md", old_text: "first", new_text: "second",
                          expected_public_id: document.fetch("public_id"),
                          expected_lock_version: document.fetch("lock_version") } }
    assert_response :success
    edited = response.parsed_body.fetch("memory")
    assert_equal "second", edited.fetch("content")
    assert_equal "notes.md", edited.fetch("path")

    post "#{door}/delete", headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: document.fetch("public_id"),
                          expected_lock_version: document.fetch("lock_version") } }
    assert_response :conflict
    assert_equal "stale_object", code

    post "#{door}/delete", headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: edited.fetch("public_id"),
                          expected_lock_version: edited.fetch("lock_version") } }
    assert_response :no_content
    assert_not @reviewer.memory_documents.exists?
  end

  test "a scope-like relative name cannot escape the named Agent's collection" do
    %w[user/notes.md workspace/notes.md conversation/notes.md speaker/notes.md].each do |path|
      write!(path, "x")
      assert_response :created
      assert_equal @collection.public_id, response.parsed_body.dig("memory", "collection_public_id")
    end
    assert_empty @owner.memory_documents
    assert_empty @agent.memory_documents
    write!("../notes.md", "x")
    assert_response :unprocessable_content
    assert_equal "memory_path_invalid", code
  end

  test "a sibling under the same steward and a Human are refused: the rung is the declarer's to manage" do
    write!("notes.md", "x", secret: @sibling_secret)
    assert_response :not_found

    write!("notes.md", "x", secret: @steward_secret)
    assert_response :not_found

    get "/agent_api/v1/profile/agents/nobody/memory_collections", headers: bearer(@agent_secret)
    assert_response :not_found
  end

  test "profile discovery separates the program's own collection from its steward's" do
    write!("notes.md", "my own notes", at: door(@own_collection))
    assert_response :created
    assert @agent.memory_documents.exists?(name: "notes.md")
    assert_empty @reviewer.memory_documents
    write!("plan.md", "the plan", at: door(@human_collection))
    assert_response :not_found
    assert_empty @owner.memory_documents

    write!("plan.md", "the plan", secret: @steward_secret, at: door(@human_collection))
    assert_response :created
    get "/agent_api/v1/profile/memory_collections", headers: bearer(@agent_secret)
    assert_response :success
    assert_equal [@own_collection.public_id], response.parsed_body.fetch("memory_collections").map { |row| row.fetch("public_id") }
    get "/agent_api/v1/profile/memory_collections", headers: bearer(@steward_secret)
    assert_response :success
    assert_equal [@human_collection.public_id], response.parsed_body.fetch("memory_collections").map { |row| row.fetch("public_id") }
    write!("notes.md", "x", secret: @steward_secret, at: door(@own_collection))
    assert_response :not_found
  end
end
