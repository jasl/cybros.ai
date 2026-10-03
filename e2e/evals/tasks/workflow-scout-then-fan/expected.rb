# REACH: a delegation — any `task` or `compose` row (which door is a fact). SUCCESS: no name was
# guessed (`Predicates.guessed_names`: a lib/ source a spine delegation's brief names that no
# read-class call of an earlier spine round returned — D6's `fan_over_guessed_names`), no qualifying
# file was handed to two delegates (`per_file <= 1`), and every loop completed; review.md naming
# exactly the five is the verification. Every name is read, never a guess of which would qualify.
# CONDUCT: the spine did not review lib/ itself — its own `read` of lib/ in a round after the one
# that handed the reviews out (adversarial-verify's rule); with nothing handed out, every such read.
files = %w[csv_out date_parse index_build ledger_close queue_drain relay_send sign_payload slug sweep_stale token_bucket
           zip_reader].map { |f| "lib/#{f}.rb" }
callers = %w[csv_out ledger_close relay_send sweep_stale token_bucket].map { |f| "lib/#{f}.rb" }
own_reads = lambda do |trace|
  keys = Trace.spine_keys(trace.graph)
  at = Predicates.dispatch_round(trace)
  after = at.nil? ? keys : keys.drop(at)
  trace.spine_calls.select do |row|
    row["tool_name"] == "read" && trace.input_of(row)["path"].to_s.include?("lib/") && Array(row["after"]).intersect?(after)
  end
end
Expected.new(
  reach: lambda do |trace|
    next true if trace.compose_rows.any? || trace.task_rows.any?

    "no delegation: the spine reviewed lib/ itself: #{trace.called.inspect}"
  end,
  success: lambda do |trace|
    guessed = Predicates.guessed_names(trace)
    next "fanned over guessed names: #{guessed.join(", ")}" unless guessed.empty?

    twice = Predicates.per_file(trace, callers).select { |_f, n| n > 1 }
    next "a file was handed to two delegates: #{twice.keys.join(", ")}" unless twice.empty?

    Predicates.every_loop_completed(trace)
  end,
  conduct: { "did_not_review_itself" => lambda do |trace|
    reads = own_reads.(trace)
    reads.empty? ? true : "the spine read #{reads.map { |r| trace.input_of(r)["path"] }.uniq.join(", ")} itself"
  end },
  facts: { "door" => ->(trace) { Predicates.door(trace) },
           "fan_over_guessed_names" => ->(trace) { Predicates.fan_over_guessed_names(trace) },
           "names_guessed" => ->(trace) { Predicates.guessed_names(trace) },
           "guessed_after_a_delegate" => ->(trace) { Predicates.guessed_after_a_delegate(trace) },
           "dispatch_door" => ->(trace) { Predicates.dispatch_door(trace) },
           "dispatch_names" => ->(trace) { Predicates.dispatch_names(trace) },
           "names_not_on_disk" => ->(trace) { Predicates.briefed_names(trace) - files },
           "per_file" => ->(trace) { Predicates.per_file(trace, callers) },
           "loop_style" => ->(trace) { Predicates.loop_style(trace) } }.merge(DOOR_FACTS)
)
