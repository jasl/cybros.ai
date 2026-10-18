files = %w[auth billing cache export import mailer search webhooks].map { |f| "lib/#{f}.rb" }
Expected.new(
  reach: ->(trace) { Predicates.reached_a_door(trace) },
  success: lambda do |trace|
    twice = Predicates.per_file(trace, files).select { |_f, n| n > 1 }
    next "a file was handed to two finders: #{twice.keys.join(", ")}" unless twice.empty?

    Predicates.every_loop_completed(trace)
  end,
  conduct: { "did_not_search_itself" => lambda do |trace|
    own = trace.mainline_calls.select { |r| r["tool_name"] == "grep" }
    own.empty? ? true : "the mainline grepped #{own.size}× itself"
  end },
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "per_file" => ->(trace) { Predicates.per_file(trace, files) },
           "loop_style" => ->(trace) { Predicates.loop_style(trace) } }.merge(DOOR_FACTS)
)
