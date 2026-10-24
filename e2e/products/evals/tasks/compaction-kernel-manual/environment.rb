# One file whose LAST line is a token that appears in the body only (the instruction never names it,
# no command ever writes it): a summary that carries it reproduced a VALUE out of a tool result — a
# pointer (`Tool read notes/brief.txt (completed, …)`) is all the arm may keep; paraphrasing a value
# is still a failure.
lambda do |seed|
  token = "brief-#{seed.secret[0, 8]}"
  body = Array.new(40) { |k| "note #{k}: the brief's filler line number #{k}" }
  { "notes/brief.txt" => ([" The brief."] + body + [token]).join("\n") + "\n" }
end
