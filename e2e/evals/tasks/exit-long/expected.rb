# REACH: the three legs were reached — a whole-file `read` of a vector,
# a `start_process` and a `read_process` completed, a write of the port.
# SUCCESS: the ladder ran (check-1 completed, the summary round the
# deliverable), every park was decided through rho's verbs (`approval.
# origin == "agent"`), no check parked, no round failed, no attention
# other than the approval park, the loop completed. The compactions are
# FACTS (mode/trigger), read beside the compaction family.
Expected.new(
  reach: lambda do |trace|
    next "no whole-file read of a vector: #{trace.called.inspect}" unless
      trace.tool_rows("read").any? { |r| trace.input_of(r)["path"].to_s.include?("spec/vectors/vec-") }
    next "the model never called start_process" if trace.tool_rows("start_process").none? { |r| r["status"] == "completed" }
    next "the model never read the server's output with read_process" if trace.tool_rows("read_process").none? { |r| r["status"] == "completed" }

    trace.calls.any? { |r| %w[write edit].include?(r["tool_name"]) && trace.input_of(r)["path"].to_s.include?("lib/frame_codec.rb") } ? true :
      "lib/frame_codec.rb was never written"
  end,
  success: lambda do |trace|
    check = trace.task("check-1")
    next "no acceptance check ran: #{trace.tasks.map { |t| t["key"] }.last(6).inspect}" if check.nil?
    next "check-1 #{check["status"]}" unless check["status"] == "completed"
    next "the summary round is not the completed deliverable" unless trace.node("summary")&.values_at("status", "deliverable") == ["completed", true]

    parks = Array(trace.fact(:park_list))
    next "nothing parked under --approval ask" if parks.empty?

    undecided = parks.reject { |park| trace.task(park["key"])&.dig("approval", "origin") == "agent" }
    next "a park was not decided through rho approve/deny: #{undecided.map { |p| p["key"] }.inspect}" unless undecided.empty?

    checks = trace.tasks.select { |t| t["key"].to_s.match?(/\Acheck-\d+\z/) }
    next "an acceptance check parked" unless (parks.map { |p| p["key"] } & checks.map { |t| t["key"] }).empty?
    next "an author's check was not pre-approved" unless checks.all? { |t| t.dig("approval", "origin") == "author" }
    next "a round did not complete: #{trace.round_errors.inspect}" unless trace.rounds.all? { |r| r["status"] == "completed" }

    other = trace.attention_reasons.keys - ["approval_required"]
    next "the feed called for a person outside the approval park: #{other.inspect}" unless other.empty?

    Predicates.loop_completed(trace)
  end,
  facts: { "compactions" => ->(trace) { trace.compaction_tally }, "parks" => ->(trace) { trace.fact(:parks) },
           "denied" => ->(trace) { trace.fact(:denied) }, "checks" => ->(trace) { trace.tasks.select { |t| t["key"].to_s.match?(/\Acheck-\d+\z/) }.map { |t| "#{t["key"]}=#{t["status"]}" } },
           "whole_vector_reads" => lambda do |trace|
             trace.tool_rows("read").count { |r| trace.input_of(r)["path"].to_s.include?("spec/vectors/vec-") && trace.input_of(r).keys.none? { |k| %w[offset limit].include?(k) } }
           end }
)
