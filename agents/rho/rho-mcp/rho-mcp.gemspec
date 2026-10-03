require_relative "lib/rho/mcp/version"

Gem::Specification.new do |spec|
  spec.name = "rho-mcp"
  spec.version = Rho::Mcp::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "The MCP client for rho's agent loop: curated tools from named servers, as an extension."
  spec.description = "rho-mcp runs the MCP servers an operator names in settings.json — a stdio server " \
    "as a child in its own scrubbed process group, a streamable-HTTP one over the official client's " \
    "own HTTP stack — lists their tools once at boot, and announces the ones the operator named " \
    "under `mcp__<server>__<tool>` with the server's own description and schema, byte for byte, " \
    "and the worst-case effect profile. It is a separate gem because an MCP client is an optional " \
    "dependency, and because the kernel never speaks MCP: an MCP server is a tool source behind an " \
    "executor, and this is the executor's half."
  spec.homepage = "https://github.com/jasl/cybros-ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-mcp"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  # THE LOADER'S CONTRACT: a gem the operator names in `extensions` is
  # required and its module answers `register(api)`. Installed is not
  # wanted: nothing here is loaded until the settings say so.
  spec.metadata["rho_extensions"] = "rho/mcp"

  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (f.end_with?(".md") && f != "README.md")
  end

  spec.add_dependency "rho-runner"
  # THE OFFICIAL CLIENT, never a hand-rolled JSON-RPC layer: `MCP::Client`
  # on `MCP::Client::Stdio` / `MCP::Client::HTTP`. Pinned to the minor
  # because rho-mcp SUBCLASSES the stdio transport (four members, three public on 1.6 —
  # `start`, `close`, `ensure_running!`, `send_notification`) and a rename
  # must fail loudly at the pin, not silently at a call.
  spec.add_dependency "mcp", "~> 1.6.0"
  # The gem's HTTP transport's two undeclared needs: its env-aware `on_data`
  # (the SSE path) wants Faraday >= 2.1, and its SSE parser is this gem. The
  # adapter is Faraday's DEFAULT (`net_http`) — the one the gem's streaming
  # path is written and tested against; httpx's adapter hands `on_data` no
  # `env` and blinds that path.
  spec.add_dependency "faraday", ">= 2.1"
  spec.add_dependency "event_stream_parser", ">= 1"
  # THE LOOPBACK CALLBACK LISTENER of `rho mcp login`: rho's ONE HTTP server library, at rho's own pin, so the
  # verb hand-parses no HTTP/1 and the CLI process needs no daemon.
  spec.add_dependency "async-http", "~> 0.90"
end
