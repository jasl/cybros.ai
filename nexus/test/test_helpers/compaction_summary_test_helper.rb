module CompactionSummaryTestHelper
  # A completed summary is the input to replay. Keep its fixture independent
  # of the provider under test while the original response and next wire run
  # through capture, composition, sealing and Build.
  def complete_compaction_summary(reader, text: "COMPACTED HISTORY", key: "summary")
    run = reader.run
    appended = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
      run: run, origin: "kernel", tip: Runs::Tasks::Tip.seed("branch"),
      steps: [Runs::Tasks::Step::Tool.new(key: key, name: "read_file", on_failure: "absorb")]
    ))
    assert_predicate appended, :applied?
    summary = run.tasks.find_by!(node_key: key)
    assert_predicate ContentBodies::Replace.call(owner: summary, role: "output",
      entries: [{ "text" => text }], seal: true), :accepted?
    summary.update_columns(status: "completed", completed_at: Time.current)
    Task.where(id: reader.id).update_all(compaction: { "summary_source" => key })
    assert_equal summary, reader.reload.arrived_summary
  end
end
