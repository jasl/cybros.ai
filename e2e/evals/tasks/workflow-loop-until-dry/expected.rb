# REACH: the model ITERATED — more than one pass, each pass a round, a receipt or a compose pass
# (the static grammar cannot loop; how it looped is the fact `loop_style`), and more than one item
# taken out of queue/ (`QueuePass`: what each bash command did — a head-pick that moves
# `queue/$head` took one — never the item names it spells). The receipt door's later passes run
# in the loops each receipt woke, whose rows the trace does not hold: once a traced bash call took
# an item, each receipt stands for the pass it woke. SUCCESS: every loop completed. CONDUCT: one
# item per pass — no bash call takes two items out or reads two items' contents, none loops over
# the queue.
queue = "queue"
Expected.new(
  reach: lambda do |trace|
    took = Predicates.queue_passes(trace, queue).count(&:took?)
    taken = took.positive? ? took + trace.receipts : 0
    fanning = trace.spine_rounds.count { |round| trace.fanned_by(round["key"]).any? }
    passes = [fanning, trace.receipts + 1, trace.compose_rows.size].max
    if passes >= 2 && taken >= 2
      true
    else
      "no iteration: #{passes} pass(es), #{took} bash call(s) took an item out of #{queue}/ and #{trace.receipts} receipt(s) came back " \
        "(#{trace.called.inspect})"
    end
  end,
  success: ->(trace) { Predicates.every_loop_completed(trace) },
  conduct: { "one_item_per_pass" => ->(trace) { Predicates.one_item_per_pass(trace, queue) } },
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "loop_style" => ->(trace) { Predicates.loop_style(trace) } }.merge(DOOR_FACTS)
)
