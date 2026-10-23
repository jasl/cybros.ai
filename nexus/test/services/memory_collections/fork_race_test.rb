require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class MemoryCollectionForkRaceTest < ActiveJob::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @human = users(:member)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human)
    @collection = MemoryCollection.default_for(@conversation)
    @collection.with_mutation do
      @anchor = Scopes::Anchor::Result.new(collection: @collection, scope: "conversation", name: "note.md", refusal: nil)
      written = MemoryDocuments::Write.call(anchor: @anchor, content: "original", expected: nil)
      assert_predicate written, :written?
      @version_id = written.document.memory_document_version_id
    end
  end

  teardown do
    begin
      release_row_lock(@held) if @held
    ensure
      stop_database_call(@call) if @call
      [@child, @conversation].compact.each do |conversation|
        next unless Conversation.exists?(conversation.id)

        Conversations::Tombstone.call(conversation: conversation.reload)
        next unless Conversation.exists?(conversation.id)

        conversation.reload.update!(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
        Conversations::Reap.call(batch: 20)
      end
      MemoryDocumentVersion.reclaim(@version_id)
    end
  end

  test "delete winning the source lock prevents fork from copying any deleted content" do
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(_source) {
      MemoryCollection.find(@collection.id).tombstone
    })
    @call = start_database_call { fork }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    result = finish_database_call(@call)
    @call = nil
    assert_predicate result, :accepted?, result.outcome.to_s
    @child = result.value
    assert_predicate @child.memory_collections.sole, :deleted?
    assert_empty @child.memory_documents
    assert_nil @child.memory_collections.sole.name
  end

  test "fork winning the source lock retains its independent pointer after source deletion and purge" do
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(_source) {
      result = fork
      assert_predicate result, :accepted?, result.outcome.to_s
      @child = result.value
    })
    @call = start_database_call { MemoryCollection.find(@collection.id).tombstone }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    finish_database_call(@call)
    @call = nil
    assert_predicate @collection.reload, :deleted?
    assert_equal 1, @collection.purge_documents(limit: 1)
    assert_equal 0, @collection.purge_documents(limit: 1)
    assert_equal "original", @child.memory_documents.sole.content
    assert_equal @version_id, @child.memory_documents.sole.memory_document_version_id
    refute MemoryDocumentVersion.reclaim(@version_id)
  end

  test "a previously resolved write refuses after the source owner is tombstoned" do
    context = MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
      principal: @human, configuration: nil, agent: nil)
    anchor = context.resolve("conversation/note.md", authoring: true)
    assert_predicate anchor, :resolved?
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(source) {
      result = Conversations::Tombstone.call(conversation: source)
      assert_predicate result, :accepted?, result.outcome.to_s
    })
    @call = start_database_call do
      context.with_locks(anchor) { MemoryDocuments::Write.call(anchor: anchor, content: "late", expected: nil) }
    end
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    result = finish_database_call(@call)
    @call = nil
    assert_equal :memory_scope_unavailable, result.outcome
    assert_equal "original", @collection.memory_documents.sole.content
  end

  test "a previously resolved write rechecks deletion after waiting for the source lock" do
    context = MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
      principal: @human, configuration: nil, agent: nil)
    anchor = context.resolve("conversation/note.md", authoring: true)
    assert_predicate anchor, :resolved?
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(_source) {
      MemoryCollection.find(@collection.id).tombstone
    })
    @call = start_database_call do
      context.with_locks(anchor) { MemoryDocuments::Write.call(anchor: anchor, content: "late", expected: nil) }
    end
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    result = finish_database_call(@call)
    @call = nil
    assert_equal :memory_scope_unavailable, result.outcome
    assert_equal "original", @collection.memory_documents.sole.content
  end

  test "a previously resolved write rechecks archive after waiting for the source lock" do
    context = MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
      principal: @human, configuration: nil, agent: nil)
    anchor = context.resolve("conversation/note.md", authoring: true)
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(_source) {
      MemoryCollection.find(@collection.id).archive
    })
    @call = start_database_call do
      context.with_locks(anchor) { MemoryDocuments::Write.call(anchor: anchor, content: "late", expected: nil) }
    end
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    result = finish_database_call(@call)
    @call = nil
    assert_equal :memory_read_only, result.outcome
    assert_equal "original", @collection.memory_documents.sole.content
  end

  test "collection creation winning the owner lock is included in the fork snapshot" do
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(source) {
      MemoryCollection.create_for(source, name: "Created before fork")
    })
    @call = start_database_call { fork }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    result = finish_database_call(@call)
    @call = nil
    assert_predicate result, :accepted?, result.outcome.to_s
    @child = result.value
    assert @child.memory_collections.exists?(name: "Created before fork")
  end

  test "fork winning the owner lock excludes a subsequently created collection" do
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(_source) {
      result = fork
      assert_predicate result, :accepted?, result.outcome.to_s
      @child = result.value
    })
    @call = start_database_call { MemoryCollection.create_for(Conversation.find(@conversation.id), name: "Created after fork") }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    finish_database_call(@call)
    @call = nil
    assert @conversation.memory_collections.exists?(name: "Created after fork")
    refute @child.memory_collections.exists?(name: "Created after fork")
  end

  test "owner collection wins over a stale default writer without a replacement identity" do
    context = MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
      principal: @human, configuration: nil, agent: nil)
    anchor = context.resolve("conversation/note.md", authoring: true)
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(source) {
      source.update!(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
      assert Conversations::Reap.reap_now(source.id)
    })
    @call = start_database_call do
      context.with_locks(anchor) { MemoryDocuments::Write.call(anchor: anchor, content: "late", expected: nil) }
    end
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    assert_raises(ActiveRecord::RecordNotFound) { finish_database_call(@call) }
    @call = nil
    refute MemoryCollection.exists?(@collection.id)
    refute MemoryDocument.exists?(memory_collection_id: @collection.id)
  end

  private

    def fork
      Conversations::Fork.call(Conversations::Fork::Command.new(conversation: Conversation.find(@conversation.id),
        acting_user: @human, turn_public_id: nil, variant_public_id: nil, title: "Independent", side: true))
    end

    def release_holder
      held, @held = @held, nil
      release_row_lock(held)
    end
end
