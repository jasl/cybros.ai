require "test_helper"

class AgentRuns::SelectedResultRecoveryTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a history summary does not discard selected inputs recovered from an unstarted failed model" do
    agent_run = seed(tool("summary", "read_file"), tool("selected", "read_file"),
      model("unavailable", "results" => ["selected"], "on_failure" => "absorb"), model("reader"), model("final"))
    finish(agent_run, "summary", "The preceding history was compacted")
    finish(agent_run, "selected", "Required selected data never sent to a provider")
    # Exercise composition from persisted settlement facts. An unavailable
    # model has no sealed request for a summary to preserve its selected data.
    node(agent_run, "unavailable").update_columns(status: "failed", error_key: "unknown_model",
      completed_at: Time.current)
    reader = node(agent_run, "reader")

    before = compose(reader)
    assert_includes before, "Required selected data never sent to a provider"
    AgentRunTask.where(id: reader.id).update_all(compaction: { "summary_source" => "summary" })

    after = compose(reader.reload)
    assert_includes after, "The preceding history was compacted"
    assert_includes after, "Required selected data never sent to a provider"
  end

  private

    def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

    def finish(agent_run, key, output)
      row = node(agent_run, key)
      stored = ContentBodies::Replace.call(owner: row, role: "output", entries: [{ "text" => output }], seal: true)
      assert_predicate stored, :accepted?
      row.update_columns(status: "completed", completed_at: Time.current)
    end

    def compose(reader)
      result = AgentRuns::InputComposition.call(node: reader, input: reader.input_value)
      assert_predicate result, :composed?
      result.elements.map(&:to_h).to_json
    end
end
