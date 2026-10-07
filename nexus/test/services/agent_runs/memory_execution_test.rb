require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class AgentRuns::MemoryExecutionTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include RowLockTestHelper

  uses_transaction :test_parallel_memory_edits_preserve_both_distinct_passages,
    :test_parallel_memory_writes_serialize_on_one_document

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @loops = []
    DevModelLane.ensure_enabled!(@account)
  end

  test "a queued memory write cannot change memory after force stop" do
    assert_stopped_call_preserves_memory("memory_write", "content" => "late replacement")
  end

  test "a queued memory edit cannot change memory after force stop" do
    assert_stopped_call_preserves_memory("memory_edit", "old_text" => "original", "new_text" => "late")
  end

  test "a queued memory delete cannot change memory after force stop" do
    assert_stopped_call_preserves_memory("memory_delete", {})
  end

  test "memory edit preserves replacement text literally" do
    write_memory("before alpha after")
    replacement = "keep \\& and \\1 literally"
    node = dispatched_call("memory_edit", "old_text" => "alpha", "new_text" => replacement)

    AgentRuns::MemoryJob.perform_now(node.id)

    assert_equal "completed", node.reload.status
    assert_not node.output_summary["is_error"] == true
    assert_equal "before #{replacement} after", memory_document.content
  end

  test "a completed memory job cannot overwrite a later document version on redelivery" do
    node = dispatched_call("memory_write", "content" => "first answer")
    AgentRuns::MemoryJob.perform_now(node.id)
    assert_equal "completed", node.reload.status
    accepted_output = node.output_body.effective_text
    written = write_memory("later answer")
    version_id = written.memory_document_version_id

    AgentRuns::MemoryJob.perform_now(node.id)

    assert_equal "later answer", memory_document.content
    assert_equal version_id, memory_document.memory_document_version_id
    assert_equal "completed", node.reload.status
    assert_equal accepted_output, node.output_body.effective_text
  end

  test "a completed memory delete cannot delete a later recreated document on redelivery" do
    write_memory("original note")
    node = dispatched_call("memory_delete", {})
    AgentRuns::MemoryJob.perform_now(node.id)
    assert_equal "completed", node.reload.status
    assert_nil memory_document
    recreated = write_memory("new document")

    AgentRuns::MemoryJob.perform_now(node.id)

    assert_not_nil memory_document
    assert_equal recreated.memory_document_version_id, memory_document.memory_document_version_id
    assert_equal "new document", memory_document.content
    assert_equal "completed", node.reload.status
  end

  test "a memory write whose deadline passed before its job cannot change the document" do
    original = write_memory("original note")
    node = dispatched_call("memory_write", "content" => "late replacement")

    travel_to(node.deadline_at + 1.second) { AgentRuns::MemoryJob.perform_now(node.id) }

    assert_equal "original note", memory_document.content
    assert_equal original.memory_document_version_id, memory_document.memory_document_version_id
    assert_equal "timed_out", node.reload.status
  end

  test "a paused memory task finishes against its frozen park clock" do
    node = dispatched_call("memory_write", "content" => "paused answer")
    paused = AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: node.agent_run, acting_user: @human
    ))
    assert_predicate paused, :accepted?

    travel_to(node.deadline_at + 1.second) { AgentRuns::MemoryJob.perform_now(node.id) }

    assert_equal "paused answer", memory_document.content
    assert_equal "completed", node.reload.status
    assert_equal "paused", node.agent_run.reload.status
  end

  test "graceful stop lets an already dispatched memory task finish" do
    node = dispatched_call("memory_write", "content" => "finishing answer")
    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: node.agent_run, acting_user: @human, force: false
    ))
    assert_predicate stopped, :accepted?
    assert_equal "canceling", node.agent_run.reload.status

    AgentRuns::MemoryJob.perform_now(node.id)

    assert_equal "finishing answer", memory_document.content
    assert_equal "completed", node.reload.status
  end

  test "a failed task settlement rolls back its memory mutation" do
    original = write_memory("original note")
    node = dispatched_call("memory_write", "content" => "uncommitted answer")
    settle = AgentRuns::Parks::Settle.method(:call)
    first = true
    interrupted = lambda do |**arguments|
      result = settle.call(**arguments)
      if first
        first = false
        raise IOError, "settlement interrupted"
      end
      result
    end

    AgentRuns::Parks::Settle.stub(:call, interrupted) { AgentRuns::MemoryJob.perform_now(node.id) }

    assert_equal "original note", memory_document.content
    assert_equal original.memory_document_version_id, memory_document.memory_document_version_id
    assert_equal "completed", node.reload.status
    assert_equal true, node.output_summary["is_error"]
    assert_includes node.output_body.effective_text, "memory_unavailable"
  end

  test "parallel memory edits preserve both distinct passages" do
    write_memory("alpha\nbeta")
    nodes = [
      dispatched_call("memory_edit", "old_text" => "alpha", "new_text" => "ALPHA"),
      dispatched_call("memory_edit", "old_text" => "beta", "new_text" => "BETA"),
    ]

    # Two active loops may edit their shared workspace note. The
    # anchor barrier makes the writers overlap reproducibly; each exact
    # replacement works against the current content under that same lock.
    execute_concurrently(nodes)

    nodes.each do |node|
      assert_equal "completed", node.reload.status
      assert_not node.output_summary["is_error"] == true
    end
    assert_equal "ALPHA\nBETA", memory_document.content
    assert_equal 2, memory_document.lock_version
  ensure
    clean_concurrent_memory
  end

  test "parallel memory writes serialize on one document" do
    nodes = [dispatched_call("memory_write", "content" => "first"),
      dispatched_call("memory_write", "content" => "second")]
    assert_difference("MemoryDocumentVersion.count", 1) { execute_concurrently(nodes) }
    nodes.each do |node|
      assert_equal "completed", node.reload.status
      assert_not node.output_summary["is_error"] == true
    end
    assert_includes ["first", "second"], memory_document.content
    assert_equal 1, memory_document.lock_version
  ensure
    clean_concurrent_memory
  end

  test "a queued whole-document write replaces the current content" do
    write_memory("original")
    node = dispatched_call("memory_write", "content" => "replacement")
    write_memory("intervening correction")

    AgentRuns::MemoryJob.perform_now(node.id)

    assert_equal "completed", node.reload.status
    assert_not node.output_summary["is_error"] == true
    assert_equal "replacement", memory_document.content
  end

  test "a queued edit refuses when its passage no longer exists" do
    write_memory("original")
    node = dispatched_call("memory_edit", "old_text" => "original", "new_text" => "replacement")
    write_memory("human correction")

    assert_no_changes -> { [memory_document.attributes, MemoryDocumentVersion.count] } do
      AgentRuns::MemoryJob.perform_now(node.id)
    end

    assert_equal "completed", node.reload.status
    assert_equal true, node.output_summary["is_error"]
    assert_includes node.output_body.effective_text, "memory_edit_not_found"
    assert_equal "human correction", memory_document.content
  end

  test "a queued delete removes the current document even after recreation" do
    original = write_memory("original")
    node = dispatched_call("memory_delete", {})
    anchor = Scopes::Anchor.call(path: "workspace/notes.md", workspace: @workspace)
    @workspace.with_lock { MemoryDocuments::Delete.call(anchor: anchor, expected: memory_expectation(original)) }
    recreated = write_memory("original")
    assert_equal original.lock_version, recreated.lock_version
    assert_not_equal original.public_id, recreated.public_id

    AgentRuns::MemoryJob.perform_now(node.id)

    assert_equal "completed", node.reload.status
    assert_not node.output_summary["is_error"] == true
    assert_nil memory_document
  end

  private

    def execute_concurrently(nodes)
      held = hold_row_lock(Workspace, @workspace.id)
      calls = nodes.map { |node| start_database_call { AgentRuns::MemoryJob.perform_now(node.id) } }
      wait_until_transitively_blocked_by(held.pid, *calls.map(&:pid))
      release_row_lock(held)
      held = nil
      calls.each { |call| finish_database_call(call) }
      calls = []
    ensure
      release_row_lock(held) if held
      calls&.each { |call| stop_database_call(call) }
    end

    def clean_concurrent_memory
      @loops.each do |agent_run|
        UsageRecord.where(model_invocation_public_id: agent_run.model_invocations.select(:public_id)).delete_all
        AgentRuns::Reap.destroy_aggregate(agent_run.reload)
      end
      anchor = Scopes::Anchor.call(path: "workspace/notes.md", workspace: @workspace)
      @workspace.with_lock { MemoryDocuments::Delete.call(anchor: anchor, expected: memory_expectation_at(anchor)) }
    end

    def assert_stopped_call_preserves_memory(name, arguments)
      written = write_memory("original note")
      version_id = written.memory_document_version_id
      node = dispatched_call(name, arguments)
      stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
        agent_run: node.agent_run, acting_user: @human
      ))
      assert_predicate stopped, :accepted?
      assert_equal "canceled", node.reload.status

      AgentRuns::MemoryJob.perform_now(node.id)

      document = memory_document
      assert_not_nil document, "the canceled call must not delete the document"
      assert_equal "original note", document.content
      assert_equal version_id, document.memory_document_version_id
      assert_equal "canceled", node.reload.status
      assert_nil node.output_body, "a late job must not manufacture a successful result"
    end

    def dispatched_call(name, arguments)
      tool = Nexus::ToolRegistry::LIVE.fetch(Nexus::ToolRegistry.resolve(name))
      agent_run = seed(model("ask", "tools" => [
        { "type" => "function", "function" => tool.wire_schema },
      ]))
      @loops << agent_run
      started = AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      assert_predicate started, :accepted?
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("calling", tool_calls: [
        { id: "call_memory", name: name,
          arguments: JSON.generate(arguments.merge("path" => "workspace/notes.md")) },
      ]))
      node = agent_run.agent_run_tasks.find_by!(tool_name: name)
      assert_equal "running", node.status, "the scheduler has dispatched the real kernel task"
      node
    end

    def write_memory(content)
      anchor = Scopes::Anchor.call(path: "workspace/notes.md", workspace: @workspace)
      result = @workspace.with_lock { MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: content) }
      assert_predicate result, :written?, result.outcome.to_s
      result.document
    end

    def memory_document = MemoryDocument.for_workspace(@workspace.id).find_by(name: "notes.md")
end
