require "test_helper"
require_relative "../../../test_helpers/row_lock_test_helper"

class Runs::ScheduleTool::RaceTest < ActiveJob::TestCase
  include RowLockTestHelper
  include RunSeamTestHelper

  self.use_transactional_tests = false

  setup do
    @calls = []
    @agent = users(:agent)
    @parent = Conversation.create!(workspace: workspaces(:shared), creating_user: @agent, answering_user: @agent)
    definitions = [Nexus::ToolRegistry.function_definition("manage_schedule")]
    seam = create_run_backed_turn(conversation: @parent, acting_user: @agent,
      agent_configuration: AgentConfiguration.capture(@agent,
      tool_definitions: definitions, approval_mode: "bypass"))
    @run = seam.run
    round = @run.tasks.create!(type: "Tasks::ModelTask", node_key: "round",
      provider_id: "dev", model_ref: "mock-text", authored_by: "author", tool_definitions: definitions)
    round.update_columns(status: "completed")
    @node = @run.tasks.create!(type: "Tasks::ToolTask", node_key: "schedule",
      tool_name: "manage_schedule", authored_by: "model", expansion_parent: round,
      tool_input: { "action" => "create", "prompt" => "Report the latest status.",
        "rule" => { "kind" => "once", "run_at" => 5.minutes.from_now.utc.iso8601 } })
    @node.update_columns(status: "running", await_started_at: Time.current,
      effect_profile: Nexus::ToolRegistry.effect_profile_for("manage_schedule"))
  end

  teardown do
    release_row_lock(@held) if @held
    @calls.each { |call| stop_database_call(call) }
    if @run && (run = Run.find_by(id: @run.id))
      run.with_lock { Runs::Reap.destroy_aggregate(run) }
    end
    destroy_memory_owner!(@parent)
  end

  test "two jobs waiting on the host create and publish one schedule" do
    @held = hold_row_lock(Conversation, @parent.id)
    2.times { @calls << start_database_call { execute } }
    wait_until_transitively_blocked_by(@held.pid, *@calls.map(&:pid))
    release_barrier

    assert_equal [:applied, :idle], @calls.map { |call| finish_database_call(call) }.sort
    assert_equal 1, @parent.schedules.count
    assert_equal @parent.schedules.sole.public_id, JSON.parse(@node.reload.output_body.effective_text).fetch("public_id")
  end

  test "stop winning before a queued schedule job prevents its side effect" do
    @held = hold_row_lock(Conversation, @parent.id, before_commit: ->(_parent) do
      Runs::Stop.call(Runs::Stop::Command.new(run: Run.find(@run.id),
        acting_user: User.find(@agent.id), force: true))
    end)
    @calls << start_database_call { execute }
    wait_until_transitively_blocked_by(@held.pid, @calls.sole.pid)
    release_barrier

    assert_equal :idle, finish_database_call(@calls.sole)
    assert_empty @parent.schedules
  end

  test "schedule creation pins its creator before the MCP principal to Run lock lane" do
    # MCP start holds the answering Agent before this same Run. The Schedule
    # creator FK must not first acquire that User after already locking the Run.
    @held = hold_row_lock(User, @agent.id, before_commit: ->(_agent) do
      Run.find(@run.id).with_lock { assert_equal "running", @node.reload.status }
    end)
    @calls << start_database_call { execute }
    wait_until_transitively_blocked_by(@held.pid, @calls.sole.pid)
    release_barrier

    assert_equal :applied, finish_database_call(@calls.sole)
    assert_equal 1, @parent.schedules.count
    assert_equal "completed", @node.reload.status
  end

  private

    def execute = Runs::ScheduleTool::Run.call(node: Task.find(@node.id))

    def release_barrier
      release_row_lock(@held)
      @held = nil
    end
end
