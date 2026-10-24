# REACH: a `memory_write` row (the kernel's wire name, tool_registry.rb:328).
# SUCCESS: the note landed under `user/` (the steward's own door lists it
# and its content carries the token) AND a conversation no loop backs, in
# a SECOND workspace of the same person, answered with the token — the
# driver's facts.
Expected.new(
  reach: ->(trace) { trace.tool_rows("memory_write").any? ? true : "no memory_write row: the model called #{trace.called.inspect}" },
  success: lambda do |trace|
    next "the note is not under user/: the person's door lists #{Array(trace.fact(:memory_paths)).inspect}" unless trace.fact(:note_under_user) == true
    next "the note's content is not the token" unless trace.fact(:note_carries_token) == true

    trace.fact(:other_workspace_carries_token) == true ? true :
      "the reply in the other workspace did not carry the token: #{trace.fact(:other_workspace_reply).inspect}"
  end,
  conduct: { "read_the_token_first" => lambda do |trace|
    read = trace.calls.index { |r| r["tool_name"] == "read" && trace.input_of(r)["path"].to_s.include?("TOKEN.txt") }
    wrote = trace.calls.index { |r| r["tool_name"] == "memory_write" }
    next "TOKEN.txt was never read" if read.nil?
    next "nothing was written" if wrote.nil?

    read < wrote ? true : "the write precedes the read"
  end }
)
