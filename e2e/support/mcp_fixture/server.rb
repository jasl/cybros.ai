# THE FIXTURE MCP SERVER: ONE `MCP::Server` from the gem, its tools from the shared declarations,
# mounted TWO WAYS by two entry points — `stdio` (the default: the gem's `StdioTransport`, launched
# by the daemon under rho's bundle — `bundle exec ruby` with `BUNDLE_GEMFILE` = rho's Gemfile in the
# row's `env`; rho's lock carries `mcp` through the `rho-mcp` path gem; the daemon's child env drops
# Bundler's own trail) and `http PORT` (the gem's `StreamableHTTPTransport` as a Rack app under puma
# on a loopback port the journey picks, spawned by the journey under rho-mcp's bundle, where puma is
# a development dependency, through `E2E::ProcessRegistry.spawn(…, pgroup: true)` so the registry's
# drain leaves nothing behind on a red run) — and, since the OAuth slice, `oauth PORT`: the SAME
# server behind rho-mcp's own mock authorization server + resource server
# (`agents/rho/rho-mcp/test/support/oauth_fixture.rb`, ONE implementation, required across the tree
# — risk 14), under puma on one loopback port: the RS at `/mcp` behind a bearer check with its PRM,
# the AS under `/oauth` with metadata, dynamic registration, an auto-consent `/authorize` carrying
# `iss`, a PKCE-verified `/token` with refresh rotation, the switches
# `/fixture/{revoke,token_outage,require_scope,…}`, the door `/fixture/expire` (every live access
# token expired at once — the journey's expiries are a property, never a clock) and the counters at
# `/fixture/issued`. Both loopback entries are spawned by the journey through
# `E2E::McpFixture::Host`. `hang` sleeps a BOUNDED twenty seconds so a red run cannot hold the
# world; `exit` leaves with status 3 mid-request. The prompts, resources and the one template are
# the announced documents (`declarations.rb`).
require "mcp"
require_relative "declarations"

decls = E2E::McpFixture::TOOLS.to_h { |tool| [tool.fetch("name"), tool] }
server = MCP::Server.new(name: E2E::McpFixture::SERVER_NAME, version: E2E::McpFixture::SERVER_VERSION,
  instructions: "A fixture server for rho's e2e journeys.")

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
  serve.call(MCP::Server::Transports::StreamableHTTPTransport.new(server), Integer(ARGV.fetch(1)))
when "oauth"
  require_relative "../../../agents/rho/rho-mcp/test/support/oauth_fixture"
  serve.call(McpTest::OauthFixture.new(server: server), Integer(ARGV.fetch(1)))
else
  MCP::Server::Transports::StdioTransport.new(server).open
end
