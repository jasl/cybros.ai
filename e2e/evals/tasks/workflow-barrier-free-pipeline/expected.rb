# REACH: a door, or the plain concurrent fan — a round of `bash` rows each
# running `bin/fetch`, or one row running it in two background jobs or
# more with a `wait` (`Predicates.concurrent_fan_round`, its round the
# `fetch_fan_round` fact); a sequence (a `for` loop, `a && b && c`) is no
# fan. SUCCESS on the strong tier: O7's EXACT edges and reads on
# the plan the compose script placed (three [fetch, normalise] pairs — each
# normaliser a model step, a tool or a value stage after its own fetch — a
# merge reading the three normalisers) AND the branch completed; on the floor,
# usable generation by a compose call of the run (`usable_on_call` the
# first-call record), the picture riding as a fact on both tiers and the
# explicit-read columns (`reads`) beside it. A `task` fan cannot spell "as
# soon as its own fetch is done", nor can the shell's fan be read as a
# picture: each is the recorded door with the reason on either tier.
# Verification: merged.txt.
fan = ->(trace) { Predicates.concurrent_fan_round(trace, "bin/fetch") }
Expected.new(
  reach: lambda do |trace|
    next true if Predicates.reached_a_door(trace) == true || fan.(trace)

    "no compose call, no round fanned two task calls and no concurrent fetch fan: #{trace.called.inspect}"
  end,
  success: lambda do |trace|
    next "the task door cannot pair a fetch with its own normaliser: #{trace.called.inspect}" if trace.compose_rows.empty?

    Predicates.compose_bar(trace, "O7")
  end,
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "score" => ->(trace) { Predicates.score_compose(trace, "O7") },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "O7") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "loop_style" => ->(trace) { Predicates.loop_style(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "O7") }, "fetch_fan_round" => fan }.merge(DOOR_FACTS)
)
