require "test_helper"

# Profile discovery yields owned collections. Document URLs fix their identity;
# relative path names cannot grant access to a steward or another owner.
class AgentAPI::V1::Profiles::MemoryTest < ActionDispatch::IntegrationTest
  setup do
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @agent_secret = connection.access_secret
    @transport_secret = connection.executor_access_secret
    @steward_secret = create_access_token_fixture(user: users(:owner), name: "S").secret
    @other_secret = create_access_token_fixture(user: users(:member), name: "M").secret
    @human_collection = MemoryCollection.default_for(users(:owner))
    @agent_collection = MemoryCollection.default_for(@agent)
  end

  def delete_fields(path)
    { path: path, **memory_conditions(@human_collection.memory_documents.find_by(name: path)) }
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def index_path(collection = @human_collection) = "/agent_api/v1/memory_collections/#{collection.public_id}/documents"
  def show_path = "#{index_path}/show"
  def delete_path = "#{index_path}/delete"

  test "an Agent cannot write its steward's collection even with the exact UUID" do
    assert_no_difference "MemoryDocument.count" do
      post index_path, headers: bearer(@agent_secret), as: :json,
        params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the plan" } }
    end
    assert_response :not_found
    assert_empty users(:owner).memory_documents
    assert_empty @agent.memory_documents
  end

  test "the Agent writes its own agent memory without changing its steward's notes" do
    post index_path(@agent_collection), headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the plan" } }

    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal "notes.md", document.fetch("path")
    assert_equal "the plan", document.fetch("content")
    assert_equal 8, document.fetch("bytesize")
    assert @agent.memory_documents.exists?(name: "notes.md")
    assert_not users(:owner).memory_documents.exists?(name: "notes.md")
  end

  test "a Human lists and reads their own memory while another Human and their Agent cannot read it" do
    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the plan" } }
    assert_response :created

    get index_path, headers: bearer(@steward_secret)
    assert_response :success
    assert_equal ["notes.md"], response.parsed_body.fetch("memory").map { |e| e.fetch("path") }

    post show_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "notes.md" } }
    assert_response :success
    assert_equal "the plan", response.parsed_body.dig("memory", "content")

    get index_path, headers: bearer(@other_secret)
    assert_response :not_found

    post show_path, headers: bearer(@other_secret), as: :json,
      params: { memory: { path: "notes.md" } }
    assert_response :not_found

    get index_path, headers: bearer(@agent_secret)
    assert_response :not_found

    post show_path, headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "notes.md" } }
    assert_response :not_found
  end

  test "relative names cannot change ownership and malformed names are refused" do
    %w[user/notes.md agent/notes.md speaker/notes.md workspace/notes.md conversation/notes.md].each do |path|
      post index_path, headers: bearer(@steward_secret), as: :json,
        params: { memory: { path: path, expected_public_id: nil, expected_lock_version: nil, content: "x" } }
      assert_response :created
      assert_equal @human_collection.public_id, response.parsed_body.dig("memory", "collection_public_id")
    end
    assert_empty @agent.memory_documents
    ["../notes.md", "/notes.md", ""].each do |path|
      post index_path, headers: bearer(@steward_secret), as: :json,
        params: { memory: { path: path, expected_public_id: nil, expected_lock_version: nil, content: "x" } }
      assert_response :unprocessable_content
      assert_equal "memory_path_invalid", response.parsed_body.dig("error", "code")
    end
  end

  test "delete is 204, and a repeated condition is stale" do
    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "gone.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :created

    observed = delete_fields("gone.md")
    post delete_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: observed }
    assert_response :no_content
    assert_not users(:owner).memory_documents.exists?(name: "gone.md")

    post delete_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: observed }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  test "a transport credential is fenced with 401 — this is the member plane" do
    get index_path, headers: bearer(@transport_secret)
    assert_response :unauthorized
  end

  test "the cap is per collection: the 65th document is memory_full" do
    MemoryDocument::MAX_DOCUMENTS_PER_COLLECTION.times do |n|
      anchor = MemoryCollections::Documents.new(collection: @human_collection, by: users(:owner)).anchor("n#{n}.md")
      MemoryDocument.transaction do
        anchor.lockable.lock!
        MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: "x")
      end
    end

    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "one-too-many.md", expected_public_id: nil, expected_lock_version: nil, content: "x" } }
    assert_response :unprocessable_content
    assert_equal "memory_full", response.parsed_body.dig("error", "code")

    post index_path(@agent_collection), headers: bearer(@agent_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "the Agent's" } }
    assert_response :created
    assert_equal "notes.md", response.parsed_body.dig("memory", "path")
  end

  # Profile memory has no Workspace anchor; a Workspace override cannot
  # replace the Human's own storage or management door.
  test "the person's own door keeps serving  while one workspace is overridden" do
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    shared = workspaces(:shared)
    assert_equal :updated, Workspaces::SetToolProviderOverrides.call(
      workspace: shared, by: users(:owner), lock_version: shared.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    ).outcome

    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "still mine" } }
    assert_response :created

    get index_path, headers: bearer(@steward_secret)
    assert_response :success
    assert_equal ["notes.md"], response.parsed_body.fetch("memory").map { |e| e.fetch("path") }

    post show_path, headers: bearer(@steward_secret), as: :json, params: { memory: { path: "notes.md" } }
    assert_response :success
    assert_equal "still mine", response.parsed_body.dig("memory", "content")

    post delete_path, headers: bearer(@steward_secret), as: :json, params: { memory: delete_fields("notes.md") }
    assert_response :no_content
  end

  # A SKILL AT THE PERSON'S DOOR: `skills/<name>` with a description, rendered on both shapes;
  # the writer's words come back as 422s through the one refusal map.
  test "skills/<name> lands with its description, renders it on both shapes, and the refusals are 422" do
    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "skills/review-checklist", expected_public_id: nil, expected_lock_version: nil, content: "# Review\n", description: "How I review." } }
    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal "skills/review-checklist", document.fetch("path")
    assert_equal "How I review.", document.fetch("description")
    assert_equal "# Review\n", document.fetch("content")

    get index_path, headers: bearer(@steward_secret)
    assert_response :success
    assert_equal [["skills/review-checklist", "How I review."]],
      response.parsed_body.fetch("memory").map { |entry| [entry.fetch("path"), entry.fetch("description")] }

    post index_path, headers: bearer(@steward_secret), as: :json,
      params: { memory: { path: "notes.md", expected_public_id: nil, expected_lock_version: nil, content: "n" } }
    assert_response :created
    assert_nil response.parsed_body.dig("memory", "description")

    { "skills/nope" => [{ content: "x" }, "skill_description_required"],
      "skills/PDF" => [{ content: "x", description: "d" }, "skill_name_invalid"],
      "plain.md" => [{ content: "x", description: "d" }, "memory_description_invalid"] }.each do |path, (fields, code)|
      post index_path, headers: bearer(@steward_secret), as: :json, params: { memory: { path: path, expected_public_id: nil, expected_lock_version: nil, **fields } }
      assert_response :unprocessable_content, path
      assert_equal code, response.parsed_body.dig("error", "code"), path
    end
  end
end
