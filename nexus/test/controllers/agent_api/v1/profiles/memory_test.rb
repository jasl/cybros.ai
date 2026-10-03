require "test_helper"

# THE PERSON'S OWN DOOR to memory's `user/` scope: the scope follows the acting user's controlling
# Human, so an agent writes its steward's notes here and the steward reads them from anywhere; a
# member of another Human's circle finds nothing. `workspace/` and `conversation/` have their own
# doors and are refused at this one.
class AgentAPI::V1::Profiles::MemoryTest < ActionDispatch::IntegrationTest
  setup do
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @agent_secret = connection.access_secret
    @transport_secret = connection.executor_access_secret
    @steward_secret = create_access_token_fixture(user: users(:owner), name: "S").secret
    @other_secret = create_access_token_fixture(user: users(:member), name: "M").secret
  end

  def delete_fields(path)
    anchor = Scopes::Anchor.call(path: path, user: users(:owner))
    { path: path, **memory_conditions(anchor.documents.find_by(name: anchor.name)) }
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def index_path = "/agent_api/v1/profile/memory"
  def show_path = "/agent_api/v1/profile/memory/show"
  def delete_path = "/agent_api/v1/profile/memory/delete"

  test "the agent writes user/, and it lands under its steward" do
    post index_path, headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the plan" } }

    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal "user/notes.md", document.fetch("path")
    assert_equal "the plan", document.fetch("content")
    assert_equal 8, document.fetch("bytesize")
    assert MemoryDocument.for_user(users(:owner).id).exists?(name: "notes.md")
    assert_not MemoryDocument.for_user(@agent.id).exists?
  end

  test "the steward lists and reads what its agent wrote; another Human finds nothing" do
    post index_path, headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the plan" } }
    assert_response :created

    get index_path, headers: bearer(@steward_secret)
    assert_response :success
    assert_equal ["user/notes.md"], response.parsed_body.fetch("memory").map { |e| e.fetch("path") }

    post show_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "user/notes.md" } }
    assert_response :success
    assert_equal "the plan", response.parsed_body.dig("memory", "content")

    get index_path, headers: bearer(@other_secret)
    assert_response :success
    assert_empty response.parsed_body.fetch("memory")

    post show_path, headers: bearer(@other_secret), as: :json,
      params: { memory: { path: "user/notes.md" } }
    assert_response :not_found
    assert_equal "memory_not_found", response.parsed_body.dig("error", "code")
  end

  test "only user/ resolves at this door; the other scopes and a bare name are refused" do
    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "workspace/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")

    post show_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "conversation/plan.md" } }
    assert_response :unprocessable_content
    assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")

    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "memory_path_invalid", response.parsed_body.dig("error", "code")
  end

  test "delete is 204, and a repeated condition is stale" do
    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "user/gone.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :created

    observed = delete_fields("user/gone.md")
    post delete_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: observed }
    assert_response :no_content
    assert_not MemoryDocument.for_user(users(:owner).id).exists?(name: "gone.md")

    post delete_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: observed }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  test "a transport credential is fenced with 401 — this is the member plane" do
    get index_path, headers: bearer(@transport_secret)
    assert_response :unauthorized
  end

  test "the cap is per person: the 65th document is memory_full" do
    MemoryDocument::MAX_DOCUMENTS_PER_ANCHOR.times do |n|
      anchor = Scopes::Anchor.call(path: "user/n#{n}.md", user: users(:owner))
      MemoryDocument.transaction do
        anchor.lockable.lock!
        MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: "x")
      end
    end

    post index_path, headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "user/one-too-many.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "memory_full", response.parsed_body.dig("error", "code")
  end

  # THE PERSON'S OWN DOOR IS NOT A WORKSPACE'S: `user/` rows are the kernel's and every
  # non-overridden workspace's turns still render them, so an override in one workspace refuses
  # nothing here.
  test "the person's own door keeps serving user/ while one workspace is overridden" do
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    shared = workspaces(:shared)
    assert_equal :updated, Workspaces::SetToolProviderOverrides.call(
      workspace: shared, by: users(:owner), lock_version: shared.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    ).outcome

    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "still mine" } }
    assert_response :created

    get index_path, headers: bearer(@steward_secret)
    assert_response :success
    assert_equal ["user/notes.md"], response.parsed_body.fetch("memory").map { |e| e.fetch("path") }

    post show_path, headers: bearer(@steward_secret), as: :json, params: { memory: { path: "user/notes.md" } }
    assert_response :success
    assert_equal "still mine", response.parsed_body.dig("memory", "content")

    post delete_path, headers: bearer(@steward_secret), as: :json, params: { memory: delete_fields("user/notes.md") }
    assert_response :no_content
  end

  # A SKILL AT THE PERSON'S DOOR: `user/skills/<name>` with a description, rendered on both shapes;
  # the writer's words come back as 422s through the one refusal map.
  test "user/skills/<name> lands with its description, renders it on both shapes, and the refusals are 422" do
    post index_path, headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "user/skills/review-checklist", expected_public_id: nil, expected_lock_version: nil, content: "# Review\n", description: "How I review." } }
    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal "user/skills/review-checklist", document.fetch("path")
    assert_equal "How I review.", document.fetch("description")
    assert_equal "# Review\n", document.fetch("content")

    get index_path, headers: bearer(@steward_secret)
    assert_response :success
    assert_equal [["user/skills/review-checklist", "How I review."]],
      response.parsed_body.fetch("memory").map { |entry| [entry.fetch("path"), entry.fetch("description")] }

    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "user/notes.md", expected_public_id: nil, expected_lock_version: nil, content: "n" } }
    assert_response :created
    assert_nil response.parsed_body.dig("memory", "description")

    { "user/skills/nope" => [{ content: "x" }, "skill_description_required"],
      "user/skills/PDF" => [{ content: "x", description: "d" }, "skill_name_invalid"],
      "user/plain.md" => [{ content: "x", description: "d" }, "memory_description_invalid"] }.each do |path, (fields, code)|
      post index_path, headers: bearer(@steward_secret), as: :json, params: { memory: { path: path, expected_public_id: nil, expected_lock_version: nil, **fields } }
      assert_response :unprocessable_content, path
      assert_equal code, response.parsed_body.dig("error", "code"), path
    end
  end
end
