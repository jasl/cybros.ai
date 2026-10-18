# REACH: the model reached for the runner's tools at all (a text-only
# answer reaches nothing). SUCCESS: the gallery's `linear?` — a chain,
# every tool fanned by one round and read by the next, no join, no await;
# fan width and round count free. CONDUCT: it ran the file it wrote with
# the command the instruction named, after writing it (row order).
Expected.new(
  reach: lambda do |trace|
    trace.calls.empty? ? "no tool call: the model answered in text (#{trace.rounds.size} rounds)" : true
  end,
  success: ->(trace) { Gallery.linear?(*trace.triple) },
  conduct: {
    "ran_the_file" => lambda do |trace|
      ran = trace.tool_rows("bash").any? { |row| Hash(row["tool_input"])["command"].to_s.include?("ruby fizzbuzz.rb") }
      ran ? true : "no bash row runs `ruby fizzbuzz.rb`: #{trace.called.inspect}"
    end,
    "wrote_before_running" => lambda do |trace|
      wrote = trace.calls.index { |row| %w[write edit].include?(row["tool_name"]) }
      ran = trace.calls.index { |row| row["tool_name"] == "bash" && Hash(row["tool_input"])["command"].to_s.include?("fizzbuzz.rb") }
      next "the file was never written by a write/edit row" if wrote.nil?
      next "the file was never run" if ran.nil?

      wrote < ran ? true : "the run (#{trace.calls[ran]["key"]}) precedes the write (#{trace.calls[wrote]["key"]})"
    end,
  }
)
