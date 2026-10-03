# THE PEER HALF: REACH: a `spawn` row whose `agent` names the peer by handle (`@reviewer` or
# `reviewer`) — a subagent, or a `task`, is not the peer. SUCCESS: the spawn waited (the person
# needed the answer in this reply), its row completed (the paired reply arrived as the call's own
# result), and the reply names line 3 (`def self.sub(a, b) = a + b`). Facts: every spawn's address
# as written, whether the peer spawn waited, the line named.
peer = "reviewer"
peer_rows = ->(trace) { trace.tool_rows("spawn").select { |row| trace.input_of(row)["agent"].to_s.delete_prefix("@") == peer } }
# `rho result` prints its status line first; the deliverable follows.
reply_body = ->(trace) { trace.reply.lines.drop(1).join }
Expected.new(
  reach: lambda do |trace|
    spawns = trace.tool_rows("spawn")
    next "no `spawn` call: the model called #{trace.called.inspect}" if spawns.empty?
    next "the spawn named no peer (agent: #{spawns.map { |r| trace.input_of(r)["agent"] }.inspect}); a subagent is not @#{peer}" if
      peer_rows.call(trace).empty?

    true
  end,
  success: lambda do |trace|
    row = peer_rows.call(trace).first
    next "no spawn addressed to @#{peer} to read" if row.nil?
    next "the spawn did not wait (wait: true): the person needed the answer in this reply" unless trace.input_of(row)["wait"] == true
    next "the spawn row #{row["key"]} #{row["status"]}: #{row.dig("error", "key").inspect}" unless row["status"] == "completed"
    next "the reply did not name line 3: #{reply_body.call(trace).strip[0, 80].inspect}" unless reply_body.call(trace).match?(/\b3\b/)

    true
  end,
  facts: { "agent" => ->(trace) { trace.tool_rows("spawn").map { |row| trace.input_of(row)["agent"] } },
           "waited" => ->(trace) { peer_rows.call(trace).any? { |row| trace.input_of(row)["wait"] == true } },
           "line_named" => ->(trace) { reply_body.call(trace)[/\b\d+\b/] } }
)
