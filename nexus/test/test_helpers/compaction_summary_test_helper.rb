module CompactionSummaryTestHelper
  # A completed summary is the input to replay. Keep its fixture independent
  # of the provider under test while the original response and next wire run
  # through capture, composition, sealing and Build.
  def complete_compaction_summary(reader, text: "COMPACTED HISTORY")
    agent_run = reader.agent_run
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel", tip: AgentRuns::Tasks::Tip.seed("branch"),
      steps: [AgentRuns::Tasks::Step::Tool.new(key: "summary", name: "read_file", on_failure: "absorb")]
    ))
    assert_predicate appended, :applied?
    summary = agent_run.agent_run_tasks.find_by!(node_key: "summary")
    assert_predicate ContentBodies::Replace.call(owner: summary, role: "output",
      entries: [{ "text" => text }], seal: true), :accepted?
    summary.update_columns(status: "completed", completed_at: Time.current)
    AgentRunTask.where(id: reader.id).update_all(compaction: { "summary_source" => "summary" })
    assert_equal summary, reader.reload.arrived_summary
  end
end
