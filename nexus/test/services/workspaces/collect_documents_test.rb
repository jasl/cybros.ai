require "test_helper"

class Workspaces::CollectDocumentsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @user = users(:owner)
  end

  test "workspace memory leaves with its anchor and its version reaches the reclaim sweep" do
    document = write_memory(@workspace, "notes.md", "room memory")
    version_id = document.memory_document_version_id
    personal = write_memory(@user, "notes.md", "personal memory")
    other = write_memory(workspaces(:personal), "notes.md", "other room")
    delete_workspace

    result = Workspaces::Collect.call(budget: 10)

    assert_equal 2, result[:processed]
    assert_not Workspace.exists?(@workspace.id)
    assert_not MemoryDocument.exists?(document.id)
    assert_equal "personal memory", personal.reload.content
    assert_equal "other room", other.reload.content
    assert MemoryDocumentVersion.exists?(version_id), "the separate sweep owns orphan versions"

    MemoryDocuments::ReclaimVersions.call
    assert_not MemoryDocumentVersion.exists?(version_id)
    assert_equal "personal memory", personal.reload.content
    assert_equal "other room", other.reload.content
  end

  test "workspace prompt leaves with its anchor while user and live room prompts remain" do
    document = write_prompt(@workspace, "character", "room character")
    personal = write_prompt(@user, "persona", "personal persona")
    other = write_prompt(workspaces(:personal), "character", "other character")
    delete_workspace

    result = Workspaces::Collect.call(budget: 10)

    assert_equal 2, result[:processed]
    assert_not Workspace.exists?(@workspace.id)
    assert_not PromptDocument.exists?(document.id)
    assert_equal "personal persona", personal.reload.content
    assert_equal "other character", other.reload.content
  end

  test "document rows share the collection budget and each committed pass can restart" do
    memory = write_memory(@workspace, "notes.md", "room memory")
    prompt = write_prompt(@workspace, "character", "room character")
    delete_workspace

    2.times do
      result = Workspaces::Collect.call(budget: 1)
      assert_equal 1, result[:processed]
      assert result.more?
      assert Workspace.exists?(@workspace.id), "the parent waits for its charged leaves"
    end
    assert_not MemoryDocument.exists?(memory.id)
    assert_not PromptDocument.exists?(prompt.id)

    assert_equal 1, Workspaces::Collect.call(budget: 1)[:processed]
    assert_not Workspace.exists?(@workspace.id)
    assert_not Workspaces::Collect.call(budget: 1).more?
  end

  test "documents remain until the workspace retention clock expires" do
    memory = write_memory(@workspace, "notes.md", "room memory")
    prompt = write_prompt(@workspace, "character", "room character")
    delete_workspace(age: 29.days)

    assert_equal 0, Workspaces::Collect.call(budget: 10)[:processed]
    assert_equal "room memory", memory.reload.content
    assert_equal "room character", prompt.reload.content
  end

  private

    def write_memory(host, name, content)
      scope = host == @user ? "user" : "workspace"
      anchor = Scopes::Anchor.call(path: "#{scope}/#{name}", workspace: host,
        conversation: nil, user: @user)
      host.with_lock do
        result = MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: content)
        assert_predicate result, :written?
        result.document
      end
    end

    def write_prompt(host, slot, content)
      anchor = host == @user ? { user: host } : { workspace: host }
      host.with_lock do
        result = PromptDocuments::Write.call(anchor: anchor, slot: slot, content: content)
        assert_predicate result, :written?
        result.document
      end
    end

    def delete_workspace(age: 31.days)
      @workspace.with_lock do
        @workspace.accept_delete
        assert_equal :completed, @workspace.complete_transition
      end
      travel age
    end
end
