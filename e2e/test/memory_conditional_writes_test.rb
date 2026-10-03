require "test_helper"
require "securerandom"
require "support/actor_provisioning"

# Two independent clients keep the observations used to prepare their edits.
# The late client represents background work calculated before a human correction;
# no private model/service calls or database state supply its preconditions.
class MemoryConditionalWritesTest < Minitest::Test
  def setup
    base_url = E2E.base_url
    steward = E2E::ActorProvisioning.world(base_url).rho_steward
    @editor = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
    @worker = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
    @workspace = @editor.workspaces.create(
      name: "Memory conditions #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @room = @editor.workspace(@workspace.public_id)
    conversation = @room.conversations.create(title: "Memory conditions", idempotency_key: SecureRandom.uuid)
    @chat = @room.conversation(conversation.public_id)
    @profile_path = "user/cas-#{SecureRandom.hex(4)}.md"
  end

  def teardown
    if @profile_path
      document = @editor.profile.memory.list.find { |entry| entry.path == @profile_path }
      @editor.profile.memory.delete(@profile_path, **condition(document)) if document
    end
  ensure
    if @workspace
      current = @editor.workspaces.fetch(@workspace.public_id)
      @room.delete(lock_version: current.lock_version)
    end
  end

  def test_old_calculations_cannot_overwrite_human_edits_or_recreated_documents_through_any_memory_door
    worker_room = @worker.workspace(@workspace.public_id)
    [
      [@editor.profile.memory, @worker.profile.memory, @profile_path],
      [@room.memory, worker_room.memory, "workspace/notes.md"],
      [@chat.memory, worker_room.conversation(@chat.public_id).memory, "conversation/notes.md"],
    ].each do |editor, worker, path|
      original = editor.write(path, "Original notes / 原始记录", expected_public_id: nil, expected_lock_version: nil)
      assert_equal 0, original.lock_version
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, original.public_id)

      human_view = editor.read(path)
      background_view = worker.read(path)
      assert_equal condition(human_view), condition(background_view)
      assert_equal human_view.content, background_view.content
      listed = worker.list.find { |entry| entry.path == path }
      assert_equal condition(background_view), condition(listed)

      corrected = editor.write(path, "Human correction / 用户修订", **condition(human_view))
      assert_equal original.public_id, corrected.public_id
      assert_equal original.lock_version + 1, corrected.lock_version
      assert_rejected_without_change(editor, worker, background_view, corrected)

      editor.delete(path, **condition(corrected))
      absent = assert_raises(CybrosAgent::Api::NotFound) { editor.read(path) }
      assert_equal "memory_not_found", absent.code
      assert_stale { worker.write(path, "late calculation", **condition(background_view)) }

      replacement = editor.write(path, "A different document / 重建的文档",
        expected_public_id: nil, expected_lock_version: nil)
      assert_equal background_view.lock_version, replacement.lock_version,
        "both rows start at zero; version alone cannot detect replacement"
      refute_equal background_view.public_id, replacement.public_id
      assert_rejected_without_change(editor, worker, background_view, replacement)

      assert_stale { worker.write(path, "another absent creator", expected_public_id: nil, expected_lock_version: nil) }
      assert_equal replacement.to_h, editor.read(path).to_h
      editor.delete(path, **condition(replacement))
    end
  end

  private

    def condition(document)
      { expected_public_id: document.public_id, expected_lock_version: document.lock_version }
    end

    def assert_stale
      error = assert_raises(CybrosAgent::Api::Conflict) { yield }
      assert_equal "stale_object", error.code
    end

    def assert_rejected_without_change(editor, worker, observed, winner)
      revision = @chat.fetch.context_revision
      assert_stale { worker.write(observed.path, "late calculation", **condition(observed)) }
      assert_stale { worker.delete(observed.path, **condition(observed)) }
      assert_equal winner.to_h, editor.read(winner.path).to_h,
        "a stale operation preserves the winning content and public version"
      assert_equal revision, @chat.fetch.context_revision,
        "rejected memory changes do not advance the conversation context"
    end
end
