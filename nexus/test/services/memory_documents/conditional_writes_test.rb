require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# HTTP callers retain their observed condition. Unlike ordinary model
# writes, concurrent proposals from one snapshot have exactly one winner.
class MemoryDocuments::ConditionalWritesTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_concurrent_creators_of_an_absent_path_have_one_winner,
    :test_concurrent_replacements_of_one_observed_version_have_one_winner

  setup do
    @workspace = workspaces(:shared)
    @path = "workspace/conditional-race.md"
  end

  test "concurrent creators of an absent path have one winner" do
    expected = MemoryDocuments::Precondition.new(public_id: nil, lock_version: nil)
    assert_difference -> { version_count }, 1 do
      assert_one_winner(concurrent_writes(expected))
    end
    assert_equal 0, document.lock_version
  ensure
    delete_document
  end

  test "concurrent replacements of one observed version have one winner" do
    created = write("original", MemoryDocuments::Precondition.new(public_id: nil, lock_version: nil)).document
    expected = memory_expectation(created)
    assert_no_difference -> { version_count } do
      assert_one_winner(concurrent_writes(expected))
    end
    assert_equal created.public_id, document.public_id
    assert_equal 1, document.lock_version
  ensure
    delete_document
  end

  private

    def concurrent_writes(expected)
      held = hold_row_lock(Workspace, @workspace.id)
      calls = %w[first second].map { |content| start_database_call { write(content, expected) } }
      wait_until_transitively_blocked_by(held.pid, *calls.map(&:pid))
      release_row_lock(held)
      held = nil
      results = calls.map { |call| finish_database_call(call) }
      calls = []
      results
    ensure
      release_row_lock(held) if held
      calls&.each { |call| stop_database_call(call) }
    end

    def assert_one_winner(results)
      assert_equal [:stale_object, :written], results.map(&:outcome).sort
      assert_includes %w[first second], document.content
      assert_equal 1, MemoryDocument.for_workspace(@workspace.id).where(name: "conditional-race.md").count
    end

    def write(content, expected)
      anchor = Scopes::Anchor.call(path: @path, workspace: Workspace.find(@workspace.id))
      anchor.lockable.with_lock do
        MemoryDocuments::Write.call(anchor: anchor, content: content, expected: expected)
      end
    end

    def document = MemoryDocument.for_workspace(@workspace.id).find_by!(name: "conditional-race.md")

    # Worker connections commit independently of this connection's cache.
    def version_count = MemoryDocumentVersion.uncached { MemoryDocumentVersion.count }

    def delete_document
      anchor = Scopes::Anchor.call(path: @path, workspace: @workspace)
      @workspace.with_lock { MemoryDocuments::Delete.call(anchor: anchor, expected: nil) }
    end
end
