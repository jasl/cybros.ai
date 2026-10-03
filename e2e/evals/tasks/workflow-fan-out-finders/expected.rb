# REACH: a door — a compose branch OR ≥ 2 `task` rows in one round (which
# one is a fact). SUCCESS: no file was searched twice by a delegate
# (`per_file <= 1`) and every loop completed; the eight tokens on disk
# are the verification. CONDUCT: it did not search the files itself — the spine's own greps, read
# off the kernel's spine mark (a finder's rounds are keyed `rN` too).
files = %w[auth billing cache export import mailer search webhooks].map { |f| "lib/#{f}.rb" }
Expected.new(
  reach: ->(trace) { Predicates.reached_a_door(trace) },
  success: lambda do |trace|
    twice = Predicates.per_file(trace, files).select { |_f, n| n > 1 }
    next "a file was handed to two finders: #{twice.keys.join(", ")}" unless twice.empty?

    Predicates.every_loop_completed(trace)
  end,
  conduct: { "did_not_search_itself" => lambda do |trace|
    own = trace.spine_calls.select { |r| r["tool_name"] == "grep" }
    own.empty? ? true : "the spine grepped #{own.size}× itself"
  end },
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "per_file" => ->(trace) { Predicates.per_file(trace, files) },
           "loop_style" => ->(trace) { Predicates.loop_style(trace) } }.merge(DOOR_FACTS)
)
