# T2 through rho: REACH: a `task` row for the suite, and the job did not go through compose — no
# compose row in or before the round that handed it out (a compose after the task is
# `compose_after_task`, a fact); `d4_right` is the D4 door objective's rule over that round, the suite
# named as success names it. SUCCESS: the suite's task is in the BACKGROUND
# (`wait != true`, the default), the lint ran direct (a bash row with rubocop), one task for the
# suite, no `start_process`. The resolver's rule is the probe's: an aliased call lands on the row
# under the kernel's name.
names_the_suite = /rails test|test suite|suite/i
Expected.new(
  reach: lambda do |trace|
    composed = Predicates.job_not_composed(trace)
    next composed unless composed == true

    trace.task_rows.any? ? true : "no `task` call: the model called #{trace.called.inspect}"
  end,
  success: lambda do |trace|
    suite = trace.task_rows.select { |row| trace.input_of(row)["prompt"].to_s.match?(names_the_suite) }
    next "no task names the suite: #{trace.task_rows.map { |r| trace.input_of(r)["prompt"].to_s[0, 60] }.inspect}" if suite.empty?
    next "the suite's task waited (wait: true): #{suite.map { |r| r["key"] }.inspect}" unless suite.any? { |row| Predicates.background?(row) }
    next "the suite was handed to #{suite.size} tasks" unless suite.one?
    next "the lint did not run direct: #{Predicates.bash_commands(trace).inspect}" unless Predicates.bash_commands(trace).any? { |c| c.include?("rubocop") }
    next "start_process was used for a command whose result was needed" if trace.tool_rows("start_process").any?

    true
  end,
  facts: { "task_calls" => ->(trace) { trace.task_rows.size },
           "suite_in_background" => ->(trace) { trace.task_rows.any? { |row| Predicates.background?(row) } },
           "d4_right" => ->(trace) { Predicates.d4_right(trace, names_the_suite) },
           "compose_after_task" => ->(trace) { Predicates.compose_after_task(trace) } }.merge(DOOR_FACTS)
)
