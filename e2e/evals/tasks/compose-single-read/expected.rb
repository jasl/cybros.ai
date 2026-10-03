# THE OVER-REACH CONTROL: one call's worth of work. REACH: the model
# reached for a plain tool at all (a read, a grep, a bash). SUCCESS: it
# composed NOTHING and delegated nothing — `compose_zero` and `task_zero`
# are the facts the text bench records, here the success itself.
Expected.new(
  reach: ->(trace) { Predicates.any_call(trace) },
  success: ->(trace) { Predicates.composed_nothing(trace) },
  facts: { "compose_zero" => ->(trace) { trace.compose_rows.empty? }, "task_zero" => ->(trace) { trace.task_rows.empty? },
           "answered_warn" => ->(trace) { trace.reply.include?("warn") } }.merge(DOOR_FACTS)
)
