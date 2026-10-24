# Task rows carry the canonical declaration selector after the model-facing role
# parameter is lowered. A waited reviewer result must arrive in this same reply.
role = "reviewer"
role_rows = ->(trace) { trace.tool_rows("spawn").select { |row| trace.input_of(row)["declaration"] == role } }
# `rho result` prints its status line first; the deliverable follows.
reply_body = ->(trace) { trace.reply.lines.drop(1).join }
Expected.new(
  reach: lambda do |trace|
    spawns = trace.tool_rows("spawn")
    next "no `spawn` call: the model called #{trace.called.inspect}" if spawns.empty?
    next "the spawn selected no reviewer role (declaration: #{spawns.map { |row| trace.input_of(row)["declaration"] }.inspect})" if
      role_rows.call(trace).empty?

    true
  end,
  success: lambda do |trace|
    row = role_rows.call(trace).first
    next "no spawn selecting #{role} to read" if row.nil?
    next "the spawn did not wait (wait: true): the person needed the answer in this reply" unless trace.input_of(row)["wait"] == true
    next "the spawn row #{row["key"]} #{row["status"]}: #{row.dig("error", "key").inspect}" unless row["status"] == "completed"
    next "the reply did not name line 3: #{reply_body.call(trace).strip[0, 80].inspect}" unless reply_body.call(trace).match?(/\b3\b/)

    true
  end,
  facts: { "role" => ->(trace) { trace.tool_rows("spawn").map { |row| trace.input_of(row)["declaration"] } },
           "waited" => ->(trace) { role_rows.call(trace).any? { |row| trace.input_of(row)["wait"] == true } },
           "line_named" => ->(trace) { reply_body.call(trace)[/\b\d+\b/] } }
)
