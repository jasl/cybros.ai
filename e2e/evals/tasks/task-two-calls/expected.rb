# GATE 0: does the model put two calls in one message at all? REACH: the
# first round fanned ≥ 2 tool rows. SUCCESS: the run's calls covered the
# three files (`Coverage`, the one reader of what a call read) and no graph
# verb was spent on three reads. CONDUCT: `no_false_claim` — the reply says
# charlie.rb defines `run` and ties neither alpha.rb nor bravo.rb to it
# (`Claims`, fail-closed: a reply it cannot read as a claim is red, never
# green). `named_charlie_only` (charlie.rb named and no other file) rides
# as a fact beside it, so the replies that only name the other files
# beside their own methods read green here and stay visible there.
files = %w[lib/alpha.rb lib/bravo.rb lib/charlie.rb]
claim = Claims::Question.new(token: "run", right: "charlie.rb", wrong: { "alpha.rb" => "start", "bravo.rb" => "go" })
Expected.new(
  reach: lambda do |trace|
    n = trace.first_round_rows.size
    n >= 2 ? true : "the first round fanned #{n} call(s), not two: #{trace.first_round_rows.map { |r| r["tool_name"] }.inspect}"
  end,
  success: lambda do |trace|
    unread = files - Coverage.covered(trace, files)
    unread.empty? ? Predicates.composed_nothing(trace) : "#{unread.join(", ")} never covered by a call"
  end,
  conduct: { "no_false_claim" => ->(trace) { Claims.check(claim, trace.reply) } },
  facts: {
    "calls_in_first_round" => ->(trace) { trace.first_round_rows.size },
    "named_charlie_only" => ->(trace) { trace.reply.include?("charlie.rb") && %w[alpha.rb bravo.rb].none? { |file| trace.reply.include?(file) } },
  }.merge(DOOR_FACTS)
)
