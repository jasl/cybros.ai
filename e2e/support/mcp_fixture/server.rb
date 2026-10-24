# Deterministic MCP tools and OAuth on a test-owned loopback server.
require "mcp"
require_relative "declarations"
require_relative "controlled_writes"

decls = E2E::McpFixture::TOOLS.to_h { |tool| [tool.fetch("name"), tool] }
writes = E2E::McpFixture::ControlledWrites.new
server = MCP::Server.new(name: E2E::McpFixture::SERVER_NAME, version: E2E::McpFixture::SERVER_VERSION,
  instructions: "A fixture server for E2E journeys.")

define = lambda do |name, &handler|
  tool = decls.fetch(name)
  server.define_tool(name: name, description: tool.fetch("description"),
    input_schema: tool.fetch("inputSchema").except("$schema"), &handler)
end

define.call("echo") do |text:|
  MCP::Tool::Response.new([{ type: "text", text: "#{E2E::McpFixture::ECHO_TEXT_PREFIX}#{text}" }])
end
define.call("lookup") do |key:, **|
  record = E2E::McpFixture::LOOKUP_RECORD.merge("key" => key)
  MCP::Tool::Response.new([{ type: "text", text: "record for #{key}: #{record.fetch("record")}" }], structured_content: record)
end
define.call("paths") do |paths:|
  MCP::Tool::Response.new([{ type: "text", text: "#{paths.length} paths" }])
end
define.call("hang") do
  sleep E2E::McpFixture::HANG_SECONDS
  MCP::Tool::Response.new([{ type: "text", text: "slept" }])
end
define.call("exit") do
  warn "fixture: leaving with status #{E2E::McpFixture::EXIT_STATUS}"
  $stderr.flush
  exit! E2E::McpFixture::EXIT_STATUS
end
define.call("write") do |text: ""|
  writes.write(text)
  MCP::Tool::Response.new([{ type: "text", text: "wrote #{text.length} bytes" }])
end
define.call("env") do
  MCP::Tool::Response.new([{ type: "text", text: ENV.keys.sort.join("\n") }])
end

fixture = E2E::McpFixture
server.define_prompt(name: "summarize", description: fixture::SUMMARIZE_DESCRIPTION) do |_args, server_context:|
  MCP::Prompt::Result.new(messages: [MCP::Prompt::Message.new(role: "user", content: MCP::Content::Text.new(fixture::SUMMARIZE_TEXT))])
end
server.define_prompt(name: "greet", description: fixture::GREET_DESCRIPTION,
  arguments: [MCP::Prompt::Argument.new(name: "who", required: true)]) do |args, server_context:|
  MCP::Prompt::Result.new(messages: [MCP::Prompt::Message.new(role: "user", content: MCP::Content::Text.new("Hello #{args["who"]}"))])
end
server.define_resource(uri: "fx://readme", name: "readme", description: fixture::README_DESCRIPTION, mime_type: "text/markdown") do
  [MCP::Resource::TextContents.new(text: fixture::README_TEXT, uri: "fx://readme", mime_type: "text/markdown")]
end
server.define_resource(uri: "fx://notes", name: "notes", description: fixture::NOTES_DESCRIPTION) do
  [MCP::Resource::TextContents.new(text: fixture::NOTES_TEXT, uri: "fx://notes", mime_type: "text/plain")]
end
server.define_resource(uri: "fx://blob", name: "blob", description: fixture::BLOB_DESCRIPTION, mime_type: "application/octet-stream") do
  [MCP::Resource::BlobContents.new(data: "AAAA", uri: "fx://blob", mime_type: "application/octet-stream")]
end
server.define_resource_template(uri_template: "fx://notes/{id}", name: "note", description: "One note by id.") { |id:| [] }

# The two loopback entries share one puma: the Rack app differs.
serve = lambda do |app, port|
  require "puma"
  require "puma/server"
  require "puma/log_writer"
  require "rack"
  puma = Puma::Server.new(app, nil, min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null)
  puma.add_tcp_listener("127.0.0.1", port)
  $stdout.puts "listening 127.0.0.1:#{port}"
  $stdout.flush
  puma.run(false)
end

case ARGV.first
when "http"
  transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
  serve.call(->(env) { writes.response(env) || transport.call(env) }, Integer(ARGV.fetch(1)))
when "oauth"
  require_relative "oauth_fixture"
  serve.call(McpTest::OauthFixture.new(server: server), Integer(ARGV.fetch(1)))
else
  MCP::Server::Transports::StdioTransport.new(server).open
end
