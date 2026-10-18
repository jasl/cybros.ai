queue = "queue"
Expected.new(
  reach: lambda do |trace|
    took = Predicates.queue_passes(trace, queue).count(&:took?)
    taken = took.positive? ? took + trace.receipts : 0
    fanning = trace.mainline_rounds.count { |round| trace.fanned_by(round["key"]).any? }
    passes = [fanning, trace.receipts + 1].max
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
