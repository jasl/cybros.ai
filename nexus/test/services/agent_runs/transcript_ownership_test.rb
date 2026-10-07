require "test_helper"

class AgentRuns::TranscriptOwnershipTest < ActiveSupport::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!
    @loop = seed(model("r1"), tool("r1t0", "read_file"))
    @parent = @loop.agent_run_tasks.find_by!(node_key: "r1t0")
  end

  test "UUID model children appear under their call with paginated continuation rounds" do
    root = plant(AgentRunTasks::ModelTask, parent: @parent)
    continuation = plant(AgentRunTasks::ModelTask, parent: root, key: "r2", reads: [root.node_key])

    assert_equal [@parent.node_key], transcript.rounds.sole.fetch(:branches)
    page = transcript(prefix: @parent.node_key, limit: 1)
    assert_equal [continuation.node_key], keys(page)
    assert page.has_older
    older = transcript(prefix: @parent.node_key, limit: 1,
      before: AgentRunTask::TranscriptCursor.decode(page.next_before))
    assert_equal [root.node_key], keys(older)
    assert_not older.has_older
    assert_equal [false], older.rounds.map { |row| row.fetch(:mainline) }
  end

  test "owned tool containers reveal model roots without requiring graph edges" do
    container = plant(AgentRunTasks::ToolTask, parent: @parent)
    root = plant(AgentRunTasks::ModelTask, parent: container)
    other_call = plant(AgentRunTasks::ToolTask, key: "r1t1")
    plant(AgentRunTasks::ModelTask, parent: other_call)

    assert_equal %w[r1t0 r1t1], transcript.rounds.sole.fetch(:branches)
    assert_equal [root.node_key], keys(transcript(prefix: @parent.node_key))
    assert_not @loop.agent_run_edges.where(from_node_id: [@parent.id, container.id]).exists?
  end

  test "hidden owned model roots do not expose their visible continuation" do
    root = plant(AgentRunTasks::ModelTask, parent: @parent, visibility: "hidden")
    plant(AgentRunTasks::ModelTask, parent: root, key: "r2", reads: [root.node_key])

    assert_equal [], transcript.rounds.sole.fetch(:branches)
    assert_equal [], keys(transcript(prefix: @parent.node_key))
  end

  test "a hidden tool container does not expose its visible model child" do
    container = plant(AgentRunTasks::ToolTask, parent: @parent, visibility: "hidden")
    plant(AgentRunTasks::ModelTask, parent: container)

    assert_equal [], transcript.rounds.sole.fetch(:branches)
    assert_equal [], keys(transcript(prefix: @parent.node_key))
  end

  private

    # Transcript is a row projection. These owned rows deliberately have no
    # graph edges, so the test also exercises the projection's data boundary.
    def plant(type, parent: nil, key: SecureRandom.uuid_v7, reads: nil, visibility: "visible")
      now = Time.current
      AgentRunTask.insert_all!([{
        account_id: @loop.account_id, agent_run_id: @loop.id, node_key: key, type: type.sti_name,
        status: "completed", authored_by: "kernel", created_at: now, updated_at: now,
        continuation_source: "branch", input_from_node_keys: reads, expansion_parent_id: parent&.id,
        transcript_visibility: visibility,
      }])
      @loop.agent_run_tasks.find_by!(node_key: key)
    end

    def transcript(**options) = AgentRuns::Transcript.call(agent_run: @loop, **options)
    def keys(result) = result.rounds.map { |row| row.fetch(:task_key) }
end
