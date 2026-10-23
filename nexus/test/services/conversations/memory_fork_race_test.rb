require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Conversations::MemoryForkRaceTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @run = create_run_backed_turn(conversation: @conversation, acting_user: @human).run
    memory = Nexus::ToolRegistry::LIVE.fetch("nexus.memory.write")
    grow!(@run, model("ask", "tools" => [{ "type" => "function", "function" => memory.wire_schema }]))
    schedule_loop!(@run)
    @name = "fork-race-#{SecureRandom.hex(8)}.md"
    run_loop_round!(@run, sse_success("remembering", tool_calls: [{
      id: "call_memory", name: "memory_write",
      arguments: JSON.generate("path" => "speaker/#{@name}", "content" => "remembered during the fork"),
    }]))
    @node = @run.tasks.find_by!(tool_name: "memory_write")
    assert_equal "running", @node.status
  end

  teardown do
    begin
      release_row_lock(@held) if @held
    ensure
      stop_database_call(@call) if @call
      [@child, @conversation].compact.each do |conversation|
        next unless Conversation.exists?(conversation.id)

        run_ids = conversation.hosted_runs.pluck(:id)
        Conversations::Turns::Cancel.stop_now(conversation.reload)
        Conversations::Turns::Converge.call(conversation_id: conversation.id)
        Conversations::Tombstone.call(conversation: conversation.reload)
        if Conversation.exists?(conversation.id)
          conversation.reload.update!(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
          Conversations::Reap.call(batch: 20)
        end
        Run.where(id: run_ids).each { |run| run.with_lock { Runs::Reap.destroy_aggregate(run) } }
      end
      # Production reclamation retains audit rows; this committed fixture
      # removes its own receipts even after their invocations have been reaped.
      UsageRecord.where(conversation_public_id: [@child, @conversation].compact.map(&:public_id)).delete_all
      if @name
        @agent.memory_documents.where(name: @name).find_each do |document|
          version_id = document.memory_document_version_id
          document.destroy!
          MemoryDocumentVersion.reclaim(version_id)
        end
      end
    end
  end

  test "a side fork completes while a speaker memory write waits for its source conversation" do
    # Memory owns its answering User before waiting for the source. Fork owns
    # the source before inserting the child's answering-User FK. A memory
    # mutex must admit that FK's KEY SHARE while still excluding other writers.
    @held = hold_row_lock(Conversation, @conversation.id, before_commit: ->(source) {
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: source, acting_user: @human, turn_public_id: nil,
        variant_public_id: nil, title: nil, side: true
      ))
      @child = result.value
      assert_predicate result, :accepted?, result.outcome.to_s
    })
    @call = start_database_call { Runs::Memory::Run.call(node: Task.find(@node.id)) }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    held, @held = @held, nil
    release_row_lock(held)
    finish_database_call(@call)
    @call = nil

    assert_predicate @child, :persisted?
    assert_equal "completed", @node.reload.status
    refute @node.output_summary["is_error"], @node.output_body.effective_text
    assert_equal "remembered during the fork", @agent.memory_documents.find_by!(name: @name).content
  end
end
