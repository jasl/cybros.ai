module E2E
  module Evals
    # THE DOOR FACTS every door-family and control task records beside its own `door`: the door as
    # the door register reads it (`Predicates.door_kind`, `door_read`), the round that handed work
    # out (`dispatch_round`), whether a scout came before it (`scout_then_door`) and that round's
    # calls (`door_calls`). A task file merges them into its `facts:` at its top level, which the
    # corpus evaluates before any lane loads the readers — so each column names `Predicates` only
    # when a verdict reads it, and the corpus loads nothing heavier than this table.
    DOOR_FACTS = {
      "door_kind" => ->(trace) { Predicates.door_kind(trace) },
      "door_read" => ->(trace) { Predicates.door_read(trace) },
      "dispatch_round" => ->(trace) { Predicates.dispatch_round(trace) },
      "scout_then_door" => ->(trace) { Predicates.scout_then_door(trace) },
      "door_calls" => ->(trace) { Predicates.door_calls(trace) },
    }.freeze
  end
end
