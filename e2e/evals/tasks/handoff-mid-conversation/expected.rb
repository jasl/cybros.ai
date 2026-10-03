# REACH: turn 1 ran a shell command on rho's own runner (a completed bash row). SUCCESS: the handoff
# verb moved the binding (no replay, no tree-sync warning), turn 2's bash rows were addressed to and
# claimed by the runner-mode rho, and rho's own runner claimed nothing after — the driver's facts,
# read off the second home's own log.
Expected.new(
  reach: lambda do |trace|
    bash = trace.tool_rows("bash")
    next "turn 1 ran no shell command: #{trace.called.inspect}" if bash.empty?

    bash.all? { |row| row["status"] == "completed" } ? true : "a turn-1 bash row did not complete: #{bash.map { |r| r["status"] }.inspect}"
  end,
  success: lambda do |trace|
    next "rho handoff did not print `handed off:`" unless trace.fact(:handed_off) == true
    next "the handoff warned that the tree is not synced" unless trace.fact(:tree_synced) == true
    next "turn 2 ran no shell command" unless trace.fact(:turn_2_bash_rows).to_i.positive?
    next "turn 2's bash was not claimed by the runner-mode rho" unless trace.fact(:turn_2_bash_on_runner) == true
    next "the runner-mode rho's own log does not show the claim" unless trace.fact(:runner_log_claimed_turn_2) == true

    trace.fact(:own_runner_idle_after) == true ? true : "rho's own runner claimed a row after the handoff"
  end,
  facts: { "turn_2_bash_rows" => ->(trace) { trace.fact(:turn_2_bash_rows) } }
)
