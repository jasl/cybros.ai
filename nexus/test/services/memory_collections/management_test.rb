require "test_helper"

class MemoryCollectionsManagementTest < ActiveSupport::TestCase
  test "management rechecks a previously loaded owner's standing inside the mutation boundary" do
    workspace = workspaces(:shared)
    owner = workspace.owner
    collection = MemoryCollection.default_for(workspace)
    access = MemoryCollections::Access.new(by: owner)
    assert access.manageable?(collection)
    assert_nil collection.name

    Workspace.find(workspace.id).update!(owner: users(:member))
    result = access.with_management(collection) do
      collection.update_metadata({ name: "Late rename" }, expected_lock_version: collection.lock_version)
    end

    assert_equal :not_authorized, result.outcome
    assert_nil collection.reload.name
  end

  test "management rechecks Conversation access after an earlier full-standing read" do
    workspace = workspaces(:shared)
    creator = users(:member)
    viewer = users(:owner)
    conversation = Conversation.create!(workspace: workspace, creating_user: creator, access_default: "full")
    collection = MemoryCollection.default_for(conversation)
    access = MemoryCollections::Access.new(by: viewer)
    assert access.manageable?(collection)

    Conversation.find(conversation.id).update!(access_default: "read")
    result = access.with_management(collection) { collection.archive(expected_lock_version: collection.lock_version) }

    assert_equal :not_authorized, result.outcome
    assert_not collection.reload.archived?
  end
end
