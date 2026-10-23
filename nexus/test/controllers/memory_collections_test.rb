require "test_helper"

class MemoryCollectionsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:owner)
    @workspace = workspaces(:shared)
    sign_in_as @human
    @collection = MemoryCollection.create_for(@workspace, name: "Project notes")
  end

  test "inventory searches and filters within readable owner scope" do
    archived = MemoryCollection.create_for(@workspace, name: "Old project")
    archived.archive
    personal = MemoryCollection.create_for(@human, name: "Personal notes")

    get memory_collections_path, params: { query: "Project" }
    assert_response :success
    assert_select "a[href=?]", memory_collection_path(@collection)
    assert_select "a[href=?]", memory_collection_path(archived), count: 0
    assert_select "a[href=?]", memory_collection_path(personal), count: 0

    get memory_collections_path, params: { status: "archived", scope: "workspace" }
    assert_select "a[href=?]", memory_collection_path(archived)
    assert_select "a[href=?]", memory_collection_path(@collection), count: 0

    get memory_collections_path, params: { query: personal.public_id, status: "all" }
    assert_select "a[href=?]", memory_collection_path(personal)

    get memory_collections_path, params: { workspace_public_id: @workspace.public_id, query: personal.public_id }
    assert_select "a[href=?]", memory_collection_path(personal), count: 0
    assert_select "input[name='workspace_public_id'][value=?]", @workspace.public_id
  end

  test "inventory searches displayed default names and treats wildcard text literally" do
    default = MemoryCollection.default_for(@human)
    get memory_collections_path, params: { query: "default", scope: "user" }
    assert_response :success
    assert_select "a[href=?]", memory_collection_path(default)
    assert_select "a[href=?]", memory_collection_path(@collection), count: 0

    get memory_collections_path, params: { query: "%" }
    assert_response :success
    assert_select "table tbody tr", count: 0
  end

  test "creation identifies its owner and contextual cancel keeps the workspace" do
    get new_memory_collection_path(workspace_public_id: @workspace.public_id)
    assert_response :success
    assert_select "a[href=?]", memory_collections_path(workspace_public_id: @workspace.public_id), text: "Cancel"
    post memory_collections_path(workspace_public_id: @workspace.public_id), params: { memory_collection: { name: "Shared research" } }
    collection = @workspace.memory_collections.find_by!(name: "Shared research")
    assert_redirected_to memory_collection_path(collection)
    get memory_collection_path(collection)
    assert_select "nav[aria-label='Collection pages'] a", text: "Documents"
  end

  test "Human console manages a collection by UUID and preserves stale metadata drafts" do
    get memory_collections_path(workspace_public_id: @workspace.public_id)
    assert_response :success
    assert_select "a[href=?]", memory_collection_path(@collection), text: "Project notes"
    get edit_memory_collection_path(@collection)
    assert_response :success
    assert_select "input[name='memory_collection[lock_version]'][value='0']"
    patch memory_collection_path(@collection), params: { memory_collection: { name: "New name", lock_version: 0 } }
    assert_redirected_to memory_collection_path(@collection)
    patch memory_collection_path(@collection), params: { memory_collection: { name: "My old draft", lock_version: 0 } }
    assert_response :conflict
    assert_select "input[name='memory_collection[name]'][value='My old draft']"
    assert_equal "New name", @collection.reload.name
    patch memory_collection_path(@collection), params: { memory_collection: { name: "Missing condition" } }
    assert_response :unprocessable_entity
    assert_equal "New name", @collection.reload.name
  end

  test "document pages pin the collection and refuse writes after archive" do
    get new_memory_collection_document_path(@collection)
    assert_response :success
    post memory_collection_documents_path(@collection), params: { memory: { path: "notes.md", content: "<script>text</script>",
      expected_public_id: "", expected_lock_version: "" } }
    assert_redirected_to memory_collection_document_path(@collection, path: "notes.md")
    get memory_collection_document_path(@collection, path: "notes.md")
    assert_response :success
    assert_select "pre", text: "<script>text</script>"
    assert_select "script", text: "text", count: 0
    document = @collection.memory_documents.sole
    @collection.archive
    patch memory_collection_document_path(@collection), params: { memory: { path: "notes.md", content: "late draft",
      expected_public_id: document.public_id, expected_lock_version: document.lock_version } }
    assert_response :forbidden
    assert_select "textarea[name='memory[content]']", text: "late draft"
    assert_equal "<script>text</script>", document.reload.content
  end

  test "a steward cannot browse Agent private collections in the console" do
    private_collection = MemoryCollection.default_for(users(:agent))
    get memory_collection_path(private_collection)
    assert_response :not_found
    get memory_collection_documents_path(private_collection)
    assert_response :not_found
  end
end
