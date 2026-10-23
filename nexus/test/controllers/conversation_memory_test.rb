require "test_helper"

class ConversationMemoryTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    @collection = MemoryCollection.default_for(@workspace)
    sign_in_as @human
  end

  test "current selection links authorized collections and projects archived access without document contents" do
    @conversation.update!(memory_context: { "bindings" => [binding(@collection)] })
    @collection.archive
    get conversation_path(@conversation)
    assert_response :success
    assert_select "section[aria-label='Current selection']" do
      assert_select "tr[data-memory-binding='project']", text: /Read only.*Archived/m
      assert_select "a[href=?]", memory_collection_path(@collection)
    end
    assert_select "section[aria-label='Active execution']", count: 0
  end

  test "active execution retains captured collection after future selection changes" do
    @conversation.update!(memory_context: { "bindings" => [binding(@collection)] })
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    original = seam.variant.memory_context
    replacement = @workspace.memory_collections.create!(name: "Next project")
    @conversation.update!(memory_context: { "bindings" => [binding(replacement)] })
    get conversation_path(@conversation)
    assert_response :success
    assert_select "section[aria-label='Current selection']" do
      assert_select "a[href=?]", memory_collection_path(replacement)
      assert_select "a[href=?]", memory_collection_path(@collection), count: 0
    end
    assert_select "section[aria-label='Active execution']" do
      assert_select "a[href=?]", memory_collection_path(@collection)
      assert_select "a[href=?]", memory_collection_path(replacement), count: 0
    end
    assert_equal original, seam.variant.reload.memory_context
  end

  test "missing capture never falls back to current defaults and reads allocate nothing" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    seam.variant.update!(memory_context: nil)
    assert_no_difference "MemoryCollection.count" do
      get conversation_path(@conversation)
    end
    assert_response :success
    assert_select "section[aria-label='Active execution']" do
      assert_select "p", text: "No available memory bindings."
      assert_select "tr[data-memory-binding]", count: 0
    end
  end

  test "private Agent collection bindings grant no Human document or management links" do
    private_collection = MemoryCollection.default_for(users(:agent))
    @conversation.update!(memory_context: { "bindings" => [binding(private_collection)] })
    get conversation_path(@conversation)
    assert_response :success
    assert_select "tr[data-memory-binding='project']", text: /Agent/
    assert_select "a[href=?]", memory_collection_path(private_collection), count: 0
    assert_select "a[href=?]", memory_collection_documents_path(private_collection), count: 0
    get memory_collection_path(private_collection)
    assert_response :not_found
  end

  test "empty selection and a concealed conversation keep their existing boundaries" do
    @conversation.update!(memory_context: { "bindings" => [] })
    get conversation_path(@conversation)
    assert_response :success
    assert_select "tr[data-memory-binding]", count: 0
    sign_out
    sign_in_as users(:owner)
    @conversation.update!(access_default: "none")
    get conversation_path(@conversation)
    assert_response :not_found
  end

  private

    def binding(collection)
      { "name" => "project", "source" => { "collection_public_id" => collection.public_id }, "access" => "read_write" }
    end
end
