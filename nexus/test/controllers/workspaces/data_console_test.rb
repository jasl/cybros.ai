require "test_helper"

class Workspaces::DataConsoleTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:shared)
    @collection = MemoryCollection.default_for(@workspace)
    @human = users(:member)
    sign_in_as @human
  end

  test "the data landing page names distinct owners and links to scoped retained content" do
    get workspace_data_path(@workspace)
    assert_response :success
    assert_select "a[href=?]", memory_collections_path(workspace_public_id: @workspace.public_id), text: "Memory collections"
    assert_select "a[href=?]", workspace_character_path(@workspace), text: "Workspace character"
    assert_select "a[href=?]", workspace_store_entries_path(@workspace), text: "Workspace Store"
    assert_select "a[href=?]", workspace_conversations_path(@workspace), text: "Browse Conversations"
    assert_select "a[href=?]", workspace_runs_path(@workspace), text: "Browse Runs"
    assert_includes response.body, "no separate file directory"
    assert_select "a[href*='/uploads/']", count: 0
  end

  test "an ordinary member creates reads edits and deletes only workspace memory" do
    create_memory(content: "<script>saved</script>")
    document = memory_document
    assert_redirected_to memory_collection_document_path(@collection, path: document.name)
    assert_nil document.memory_collection.user_id
    assert_nil document.memory_collection.conversation_id

    get memory_collection_documents_path(@collection)
    assert_response :success
    assert_select "a[href=?]", memory_collection_document_path(@collection, path: document.name), text: document.name
    assert_not_includes response.body, "&lt;script&gt;saved"

    get memory_collection_document_path(@collection, path: document.name)
    assert_response :success
    assert_select "pre", text: "<script>saved</script>"
    assert_select "script", text: "saved", count: 0
    get edit_memory_collection_document_path(@collection, path: document.name)
    assert_select "input[name='memory[expected_public_id]'][value=?]", document.public_id
    assert_select "input[name='memory[expected_lock_version]'][value='0']"

    patch memory_collection_document_path(@collection), params: { memory: memory_fields(document).merge(content: "Changed") }
    assert_response :see_other
    assert_equal "Changed", document.reload.content
    delete memory_collection_document_path(@collection), params: { memory: memory_fields(document) }
    assert_redirected_to memory_collection_documents_path(@collection)
    assert_not MemoryDocument.exists?(id: document.id)
  end

  test "memory refuses malformed names and preserves failed text without granting an unconditional write" do
    ["../notes.md", "/notes.md", "UPPER.md", ""].each do |path|
      post memory_collection_documents_path(@collection), params: {
        memory: { path: path, content: "draft", expected_public_id: "", expected_lock_version: "" },
      }
      assert_response :unprocessable_entity
      assert_select "textarea[name='memory[content]']", text: "draft"
      assert_empty @workspace.memory_documents
    end
    create_memory
    original = memory_document.content
    patch memory_collection_document_path(@collection), params: { memory: { path: "notes.md", content: "No precondition" } }
    assert_response :unprocessable_entity
    assert_select "textarea[name='memory[content]']", text: "No precondition"
    assert_equal original, memory_document.content
    patch memory_collection_document_path(@collection), params: {
      memory: memory_fields(memory_document).merge(content: "Invalid", expected_lock_version: "0junk"),
    }
    assert_response :unprocessable_entity
    assert_equal original, memory_document.content
  end

  test "stale memory edits and deletes cannot overwrite a replacement and keep original conditions" do
    create_memory(content: "Original")
    document = memory_document
    stale = memory_fields(document)
    patch memory_collection_document_path(@collection), params: { memory: stale.merge(content: "Newer") }
    assert_response :see_other
    patch memory_collection_document_path(@collection), params: { memory: stale.merge(content: "My draft") }
    assert_response :conflict
    assert_select "textarea[name='memory[content]']", text: "My draft"
    assert_select "input[name='memory[expected_public_id]'][value=?]", stale.fetch(:expected_public_id)
    assert_select "input[name='memory[expected_lock_version]'][value='0']"
    assert_select "a[target='_blank'][href=?]", memory_collection_document_path(@collection, path: document.name)
    assert_equal "Newer", document.reload.content

    delete memory_collection_document_path(@collection), params: { memory: stale }
    assert_response :conflict
    delete memory_collection_document_path(@collection), params: { memory: memory_fields(document) }
    assert_response :see_other
    create_memory(content: "Recreated")
    patch memory_collection_document_path(@collection), params: { memory: stale.merge(content: "Old identity") }
    assert_response :conflict
    assert_equal "Recreated", memory_document.content
    assert_not_equal stale.fetch(:expected_public_id), memory_document.public_id
  end

  test "create only memory conditions do not replace an occupied path and a failed skill keeps its draft" do
    create_memory(content: "Original")
    post memory_collection_documents_path(@collection), params: {
      memory: { path: "notes.md", content: "Collision", expected_public_id: "", expected_lock_version: "" },
    }
    assert_response :conflict
    assert_equal "Original", memory_document.content
    post memory_collection_documents_path(@collection), params: {
      memory: { path: "skills/commits", content: "# Draft", expected_public_id: "", expected_lock_version: "" },
    }
    assert_response :unprocessable_entity
    assert_select "textarea[name='memory[content]']", text: "# Draft"
    assert_includes response.body, I18n.t("data_console.errors.skill_description_required")
  end

  test "memory override blocks the ordinary list and documents but retains exact skill access" do
    create_memory
    provider = connect_provider(identifier: "data-memory", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    assert_equal :updated, ::Workspaces::SetToolProviderOverrides.call(
      workspace: @workspace, by: users(:owner), lock_version: @workspace.reload.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    ).outcome
    get memory_collection_documents_path(@collection)
    assert_response :conflict
    assert_includes response.body, provider.display_name
    assert_not_includes response.body, I18n.t("data_console.memory.empty")
    assert_select "form[action=?][method=get]", memory_collection_document_path(@collection) do
      assert_select "input[name=path]"
    end
    get memory_collection_document_path(@collection, path: "notes.md")
    assert_response :conflict
    patch memory_collection_document_path(@collection), params: { memory: memory_fields(memory_document).merge(content: "Override draft") }
    assert_response :conflict
    assert_select "textarea[name='memory[content]']", text: "Override draft"
    assert_select "input[type=submit]", count: 0

    path = "skills/commits"
    get new_memory_collection_document_path(@collection, path: path)
    assert_response :success
    post memory_collection_documents_path(@collection), params: {
      memory: { path: path, content: "# Commits", description: "Commit instructions", expected_public_id: "", expected_lock_version: "" },
    }
    assert_response :see_other
    get memory_collection_document_path(@collection, path: path)
    assert_response :success
    assert_select "pre", text: "# Commits"
    skill = @workspace.memory_documents.find_by!(name: "skills/commits")
    delete memory_collection_document_path(@collection), params: { memory: memory_fields(skill) }
    assert_response :see_other
  end

  test "character saves whole replacements and distinguishes empty text from deletion" do
    put workspace_character_path(@workspace), params: { prompt_document: { content: "Room {{workspace}}", role: "developer" } }
    assert_redirected_to workspace_character_path(@workspace)
    document = @workspace.prompt_documents.find_by!(slot: "character")
    assert_equal ["Room {{workspace}}", "developer", 1], [document.content, document.role, document.version]

    put workspace_character_path(@workspace), params: { prompt_document: { content: "" } }
    assert_response :see_other
    assert_equal ["", "system", 2], [document.reload.content, document.role, document.version]
    get workspace_character_path(@workspace)
    assert_select "button", text: "Delete character"
    assert_not_includes response.body, I18n.t("data_console.character.empty")
    delete workspace_character_path(@workspace)
    assert_response :see_other
    get workspace_character_path(@workspace)
    assert_includes response.body, I18n.t("data_console.character.empty")
    assert_select "button", text: "Delete character", count: 0
  end

  test "invalid character preserves draft role and saved content" do
    put workspace_character_path(@workspace), params: { prompt_document: { content: "Saved", role: "system" } }
    put workspace_character_path(@workspace), params: { prompt_document: { content: "{{unknown_macro}} <script>draft</script>", role: "user" } }
    assert_response :unprocessable_entity
    assert_select "textarea[name='prompt_document[content]']", text: "{{unknown_macro}} <script>draft</script>"
    assert_select "select[name='prompt_document[role]'] option[selected][value=user]"
    assert_select "script", text: "draft", count: 0
    assert_equal "Saved", @workspace.prompt_documents.find_by!(slot: "character").content
  end

  test "Store create retries use the shared receipt and mismatch retains the request key" do
    fields = { namespace: "my.app", key: "current", value_json: "null", idempotency_key: SecureRandom.uuid_v7 }
    post workspace_store_entries_path(@workspace), params: { store_entry: fields }
    assert_response :see_other
    assert_equal "false", response.headers["Idempotency-Replayed"]
    entry = @workspace.store_entries.sole
    assert_nil entry.value
    assert_redirected_to workspace_store_entry_path(@workspace, entry.public_id)
    post workspace_store_entries_path(@workspace), params: { store_entry: fields }
    assert_response :see_other
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal entry.id, @workspace.store_entries.sole.id

    secret = create_access_token_fixture(user: @human, name: "Data interoperability").secret
    post "/agent_api/v1/workspaces/#{@workspace.public_id}/store_entries", as: :json,
      headers: { "Authorization" => "Bearer #{secret}", "Idempotency-Key" => fields.fetch(:idempotency_key) },
      params: { store_entry: { namespace: "my.app", key: "current", value: nil } }
    assert_response :created
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal entry.public_id, response.parsed_body.dig("store_entry", "public_id")

    post workspace_store_entries_path(@workspace), params: { store_entry: fields.merge(value_json: "false") }
    assert_response :conflict
    assert_select "textarea[name='store_entry[value_json]']", text: "false"
    assert_select "input[name='store_entry[idempotency_key]'][value=?]", fields.fetch(:idempotency_key)
    assert_nil entry.reload.value
  end

  test "Store values round trip opaque arrays false and null with fixed coordinates" do
    entry = create_store(value: false)
    get workspace_store_entry_path(@workspace, entry.public_id)
    assert_select "pre", text: "false"
    get edit_workspace_store_entry_path(@workspace, entry.public_id)
    assert_select "input[name='store_entry[namespace]']", count: 0
    assert_select "input[name='store_entry[key]']", count: 0
    patch workspace_store_entry_path(@workspace, entry.public_id), params: {
      store_entry: { namespace: "renamed", key: "other", value_json: '[false,null,{"nested":[1,"text"]}]', lock_version: entry.lock_version },
    }
    assert_response :see_other
    assert_equal [false, nil, { "nested" => [1, "text"] }], entry.reload.value
    assert_equal ["app", "current"], [entry.namespace, entry.key]
    patch workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { value_json: "null", lock_version: entry.lock_version } }
    assert_response :see_other
    assert_nil entry.reload.value
    delete workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { lock_version: entry.lock_version } }
    assert_redirected_to workspace_store_entries_path(@workspace)
    assert_not StoreEntry.exists?(id: entry.id)
  end

  test "invalid and stale Store writes preserve the draft without adopting a newer version" do
    entry = create_store(value: { "saved" => true })
    old_version = entry.lock_version
    entry.update!(value: "Newer")
    patch workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { value_json: '{"my":"draft"}', lock_version: old_version } }
    assert_response :conflict
    assert_select "textarea[name='store_entry[value_json]']", text: '{"my":"draft"}'
    assert_select "input[name='store_entry[lock_version]'][value=?]", old_version.to_s
    assert_equal "Newer", entry.reload.value
    delete workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { lock_version: old_version } }
    assert_response :conflict
    assert_select "button", text: "Delete", count: 0
    patch workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { value_json: "{ broken", lock_version: old_version } }
    assert_response :unprocessable_entity
    assert_select "textarea[name='store_entry[value_json]']", text: "{ broken"
    patch workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { value_json: "false", lock_version: "0junk" } }
    assert_response :unprocessable_entity
    assert_equal "Newer", entry.reload.value
  end

  test "Store lists filter before bounded pagination and never load values into list output" do
    26.times { |index| @workspace.store_entries.create!(namespace: "app", key: "entry-%02d" % index, value: "private-value") }
    @workspace.store_entries.create!(namespace: "other", key: "other-entry", value: true)
    get workspace_store_entries_path(@workspace, namespace: "app")
    assert_response :success
    assert_select "article", count: 25
    assert_not_includes response.body, "private-value"
    assert_not_includes response.body, "other-entry"
    get workspace_store_entries_path(@workspace, namespace: "app", page: 2)
    assert_select "article", count: 1
    assert_select "article a", text: "entry-25"
  end

  test "archived data is readable without write controls and restoring follows live write semantics" do
    create_memory
    entry = create_store(value: false)
    @workspace.update!(state: "archived", archived_at: Time.current)
    [workspace_data_path(@workspace), memory_collection_documents_path(@collection),
      memory_collection_document_path(@collection, path: "notes.md"), workspace_character_path(@workspace),
      workspace_store_entries_path(@workspace), workspace_store_entry_path(@workspace, entry.public_id)].each do |path|
      get path
      assert_response :success
      [new_memory_collection_document_path(@collection), edit_memory_collection_document_path(@collection, path: "notes.md"),
        edit_workspace_character_path(@workspace), new_workspace_store_entry_path(@workspace),
        edit_workspace_store_entry_path(@workspace, entry.public_id)].each do |write_path|
        assert_select "a[href=?]", write_path, count: 0
      end
      [memory_collection_document_path(@collection), workspace_character_path(@workspace),
        workspace_store_entry_path(@workspace, entry.public_id)].each do |write_path|
        assert_select "form[action=?]", write_path, count: 0
      end
    end
    patch memory_collection_document_path(@collection), params: { memory: memory_fields(memory_document).merge(content: "Archived draft") }
    assert_response :forbidden
    assert_select "textarea[name='memory[content]'][readonly]", text: "Archived draft"
    assert_select "input[type=submit]", count: 0
    put workspace_character_path(@workspace), params: { prompt_document: { content: "Archived character" } }
    assert_response :conflict
    patch workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { value_json: "true", lock_version: entry.lock_version } }
    assert_response :conflict
    assert_equal false, entry.reload.value

    @workspace.update!(state: "restoring")
    patch memory_collection_document_path(@collection), params: { memory: memory_fields(memory_document).merge(content: "Restoring memory") }
    assert_response :see_other
    put workspace_character_path(@workspace), params: { prompt_document: { content: "Restoring character" } }
    assert_response :see_other
    patch workspace_store_entry_path(@workspace, entry.public_id), params: { store_entry: { value_json: "true", lock_version: entry.lock_version } }
    assert_response :see_other
    assert_equal true, entry.reload.value
  end

  test "private workspace data stays concealed even from an Account admin and entries cannot cross hosts" do
    entry = create_store(value: "Shared")
    [@human, users(:owner)].each do |human|
      sign_out
      sign_in_as human
      get workspace_data_path(workspaces(:personal))
      assert_response :not_found
      put workspace_character_path(workspaces(:personal)), params: { prompt_document: { content: "No access" } }
      assert_response :not_found
    end
    other = @human.account.workspaces.create!(creator: @human, owner: @human, name: "Other", access_mode: :account_wide)
    get workspace_store_entry_path(other, entry.public_id)
    assert_response :not_found
    sign_out
    get workspace_data_path(@workspace)
    assert_redirected_to new_session_path(return_to: workspace_data_path(@workspace))
  end

  private

    def create_memory(content: "Saved")
      post memory_collection_documents_path(@collection), params: {
        memory: { path: "notes.md", content: content, expected_public_id: "", expected_lock_version: "" },
      }
      assert_response :see_other
    end

    def memory_document
      @workspace.memory_documents.find_by!(name: "notes.md")
    end

    def memory_fields(document)
      { path: document.name, expected_public_id: document.public_id, expected_lock_version: document.lock_version }
    end

    def create_store(value:)
      post workspace_store_entries_path(@workspace), params: {
        store_entry: { namespace: "app", key: "current", value_json: JSON.generate(value), idempotency_key: SecureRandom.uuid_v7 },
      }
      assert_response :see_other
      @workspace.store_entries.find_by!(namespace: "app", key: "current")
    end
end
