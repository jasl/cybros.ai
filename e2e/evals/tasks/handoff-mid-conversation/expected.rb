# REACH: turn 1 ran a shell command on rho's own Runner. SUCCESS: the default
# changed and the following turn's shell calls were claimed by the selected Runner.
# The corpus keeps its historical task slug; no accepted task is readdressed.
Expected.new(
  reach: lambda do |trace|
    bash = trace.tool_rows("bash")
    next "turn 1 ran no shell command: #{trace.called.inspect}" if bash.empty?

    bash.all? { |row| row["status"] == "completed" } ? true : "a turn-1 bash row did not complete: #{bash.map { |r| r["status"] }.inspect}"
  end,
  success: lambda do |trace|
    next "rho set_default_runner did not print the new default" unless trace.fact(:default_runner_changed) == true
    next "turn 2 ran no shell command" unless trace.fact(:turn_2_bash_rows).to_i.positive?
    next "turn 2's bash was not claimed by the runner-mode rho" unless trace.fact(:turn_2_bash_on_runner) == true
    next "the runner-mode rho's own log does not show the claim" unless trace.fact(:runner_log_claimed_turn_2) == true

    trace.fact(:own_runner_idle_after) == true ? true : "rho's own runner claimed a row after the default changed"
  end,
  facts: { "turn_2_bash_rows" => ->(trace) { trace.fact(:turn_2_bash_rows) } }
)
