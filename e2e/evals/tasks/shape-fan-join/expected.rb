# REACH: a compose call. SUCCESS: the gallery's `fan_join?` — ONE compose
# call whose branch fans ≥ 2 model steps that ONE later model step reads
# (an `all` fan places no join row; a race would), the merge completed.
# CONDUCT: no `task` call (the text says so); the reply names every file.
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Gallery.fan_join?(*trace.triple) },
  conduct: {
    "no_task_tool" => ->(trace) { trace.task_rows.empty? ? true : "the model used `task` #{trace.task_rows.size}×" },
    "reply_names_all_five" => lambda do |trace|
      missing = %w[a b c d e].reject { |f| trace.reply.include?("#{f}.rb") }
      missing.empty? ? true : "the reply names no lib/#{missing.first}.rb"
    end,
  },
  facts: { "orphans_named" => ->(trace) { %w[a b c d e].count { |f| trace.reply.include?("orphan_#{f}") } } }
)
