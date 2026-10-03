# THE FULL-SET OVER-REACH CONTROL: three greps, no `task`, no `compose`.
# REACH: the run's calls covered the three files (`Coverage`: a read, a
# grep of the folder or under a glob, a content reader in bash, a
# delegation naming them), read over EVERY round — a first round spent
# listing the folder still reaches, so a later delegation is scored as the
# over-reach it is. SUCCESS: no graph verb at all. CONDUCT: the reply names
# db.yml and cache.yml and not app.yml. FACTS: `calls_in_first_round` shows
# whether the model fanned in one message, `covered` and
# `covered_in_first_round` what the run and its first round read.
files = %w[config/app.yml config/db.yml config/cache.yml]
Expected.new(
  reach: lambda do |trace|
    covered = Coverage.covered(trace, files)
    missing = files - covered
    if missing.empty?
      true
    else
      calls = trace.calls.map { |row| "#{row["tool_name"]} #{trace.input_of(row).to_json[0, 80]}" }
      "the calls covered #{covered.size} of the #{files.size} files (#{missing.join(", ")} unread): #{calls.join("; ")}"
    end
  end,
  success: ->(trace) { Predicates.composed_nothing(trace) },
  conduct: {
    "named_db_and_cache" => lambda do |trace|
      missing = %w[db.yml cache.yml].reject { |f| trace.reply.include?(f) }
      next "the reply does not name #{missing.join(", ")}" unless missing.empty?

      trace.reply.include?("app.yml") && !trace.reply.match?(/app\.yml[^\n]*(not|false|no)/i) ? "the reply also names app.yml" : true
    end,
  },
  facts: { "task_zero" => ->(trace) { trace.task_rows.empty? }, "compose_zero" => ->(trace) { trace.compose_rows.empty? },
           "calls_in_first_round" => ->(trace) { trace.first_round_rows.size },
           "covered" => ->(trace) { Coverage.covered(trace, files) },
           "covered_in_first_round" => ->(trace) { Coverage.covered(trace, files, rows: trace.first_round_rows) } }.merge(DOOR_FACTS)
)
