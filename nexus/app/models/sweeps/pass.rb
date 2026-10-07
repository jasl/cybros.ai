module Sweeps
  # THE ONE RESULT A BOUNDED SWEEP ANSWERS: what the pass counted, under the
  # sweep's own names — `{scanned:, reaped:}`, `{marked:, reaped:, scanned:}`
  # — the cursor the continuation hand-carries (nil where the acted rows leave
  # the source set; an array where the sweep walks two phases, splatted into
  # the job), and whether a full window asks for another hop. Indexed by
  # counter name so a reader that asks for a count the sweep never took is
  # refused, never nil.
  Pass = Data.define(:counts, :cursor, :more) do
    def initialize(counts:, more:, cursor: nil) = super(counts: counts.freeze, cursor: cursor, more: more)

    def [](name) = counts.fetch(name)

    def more? = more
  end
end
