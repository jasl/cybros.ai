# THE REAL CHILD for the spawn tests: one `MCP::Server` from the gem on
# its stdio transport — `echo`, `env` (the process's environment keys:
# the scrub pin), `hang` (a bounded sleep), `exit` (exits 3 mid-request),
# `whisper` (writes the token it was given to stderr: the redaction pin),
# `reveal` (answers the token in its text and its structure: the
# model-read redaction pin), and the resource `fx://secret` carrying it.
# `sleep` as the first argument spawns a process that never speaks (the
# startup bound's fixture); `crash` one that exits 7 before answering.
require "mcp"

case ARGV.first
when "sleep" then sleep 60
when "crash"
  warn "fixture: cannot start (#{ENV["FX_TOKEN"]})"
  exit 7
else nil
end

server = MCP::Server.new(name: "fx-server", version: "1.0.0", instructions: "Be kind to the operator.")
server.define_tool(name: "echo", description: "Echo the text back, unchanged.",
  input_schema: { properties: { text: { type: "string" } }, required: ["text"] }) do |text:|
  MCP::Tool::Response.new([{ type: "text", text: text }])
end
server.define_tool(name: "env", description: "List the environment's keys.",
  input_schema: { properties: {} }) do
  MCP::Tool::Response.new([{ type: "text", text: ENV.keys.sort.join("\n") }])
end
server.define_tool(name: "hang", description: "Sleep for twenty seconds.",
  input_schema: { properties: {} }) do
  sleep 20
  MCP::Tool::Response.new([{ type: "text", text: "slept" }])
end
server.define_tool(name: "exit", description: "Exit with status 3 mid-request.",
  input_schema: { properties: {} }) do
  warn "fixture: leaving now (#{ENV["FX_TOKEN"]})"
  $stderr.flush
  exit! 3
end
server.define_tool(name: "whisper", description: "Write the token to stderr and answer.",
  input_schema: { properties: {} }) do
  warn "fixture: the token is #{ENV["FX_TOKEN"]}"
  $stderr.flush
  MCP::Tool::Response.new([{ type: "text", text: "whispered" }])
end
server.define_tool(name: "reveal", description: "Answer the token in text and structure.",
  input_schema: { properties: {} }) do
  MCP::Tool::Response.new([{ type: "text", text: "the token is #{ENV["FX_TOKEN"]}" }],
    structured_content: { "token" => ENV["FX_TOKEN"] })
end
server.define_resource(uri: "fx://secret", name: "secret", description: "Holds the token.", mime_type: "text/plain") do
  [MCP::Resource::TextContents.new(text: "secret=#{ENV["FX_TOKEN"]}", uri: "fx://secret", mime_type: "text/plain")]
end
MCP::Server::Transports::StdioTransport.new(server).open
