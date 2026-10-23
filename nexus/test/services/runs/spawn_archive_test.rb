require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"
require_relative "../../test_helpers/run_seam_test_helper"

class Runs::SpawnArchiveTest < ActiveJob::TestCase
  include RowLockTestHelper
  include RunSeamTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @root = Conversation.create!(workspace: @workspace, creating_user: @agent)
    @parent = Conversation.create!(workspace: @workspace, creating_user: @agent,
      parent_conversation: @root, parent_conversation_public_id: @root.public_id)
    @run = create_run_backed_turn(conversation: @parent, acting_user: @agent).run
    @node = @run.tasks.create!(type: "Tasks::ToolTask", node_key: "spawn",
      tool_name: "spawn", tool_input: { "prompt" => "continue accepted work", "model" => "dev/mock-text" },
      authored_by: "model")
    Runs::ScheduleReady.call(run_id: @run.id)
    assert_equal "running", @node.reload.status
    clear_enqueued_jobs
  end

  teardown do
    if @run && (run = Run.find_by(id: @run.id))
      run.with_lock { Runs::Reap.destroy_aggregate(run) }
    end
    if @root && (root = Conversation.find_by(id: @root.id))
      members = Conversations::SubagentTree.members(root)
      ConversationCommandReceipt.where(host_type: "Conversation", host_id: members.select(:id)).delete_all
      members.order(id: :desc).each do |conversation|
        conversation.memory_collections.delete_all
        conversation.destroy!
      end
    end
  end

  test "archive committed during nested child birth keeps the late child archived" do
    birth_after(Conversations::Archive)

    assert_predicate spawned_child, :archived?
    assert_predicate @parent.reload, :archived?
    assert_equal @parent.id, spawned_child.parent_conversation_id
    assert_equal "continue accepted work", spawned_child.inputs.sole.text
  end

  test "unarchive committed during nested child birth keeps the late child restored" do
    assert_predicate Conversations::Archive.call(conversation: @root), :accepted?
    birth_after(Conversations::Unarchive)

    assert_not spawned_child.archived?
    assert_not @parent.reload.archived?
    assert_equal "continue accepted work", spawned_child.inputs.sole.text
  end

  private

    def spawned_child = Conversation.find_by!(spawn_node_id: @node.id)

    def birth_after(command)
      held = hold_row_lock(Conversation, @root.id, before_commit: ->(root) { command.call(conversation: root) })
      birth = start_database_call { Runs::Spawn::Run.call(node: Task.find(@node.id)) }
      wait_until_transitively_blocked_by(held.pid, birth.pid)

      release_row_lock(held)
      held = nil
      assert_equal :applied, finish_database_call(birth)
      birth = nil
    ensure
      begin
        release_row_lock(held) if held
      ensure
        stop_database_call(birth) if birth
      end
    end
end
