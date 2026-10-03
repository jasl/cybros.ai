require_relative "lib/rho/acp-client/version"

Gem::Specification.new do |spec|
  spec.name = "rho-acp-client"
  spec.version = Rho::AcpClient::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "rho as an ACP client: another agent delegated to, as an extension."
  spec.description = "rho-acp-client lets a model running through rho hand a task to another ACP agent " \
    "an operator names in settings.json — `delegate_agent`, one child process per (conversation, " \
    "agent), its permission requests relayed to rho's own floor and never proxied, its cancel " \
    "cascaded, the management verbs and `GET /acp`. It is a separate gem in rho-mcp's shape " \
    "because a client to other agents is an optional dependency, and because the kernel never " \
    "speaks ACP: a delegated agent is a tool behind an executor, and this is the executor's half. " \
    "It depends on rho-acp for the wire and on rho-runner for the row-secrets rule and the " \
    "child-env scrub."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-acp-client"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  # THE LOADER'S CONTRACT: a gem the operator names in `extensions` is
  # required and its module answers `register(api)`. Installed is not
  # wanted: nothing here is loaded until the settings say so.
  spec.metadata["rho_extensions"] = "rho/acp-client"

  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (f.end_with?(".md") && f != "README.md")
  end

  # The daemon's handle (`Rho::Extensions::Api`: routes, commands, the
  # daemon hooks), `Rho::Config`'s opaque `acp_agents` table.
  spec.add_dependency "rho"
  # `Result`, `ToolEnv`, `ExecutionContext`, `OwnedProcess` and the
  # child-env scrub — the tool's body and its process-group rule.
  spec.add_dependency "rho-runner"
  # THE WIRE: the framing, the two-way connection and the method names
  # are the agent gem's, spoken from the other end.
  spec.add_dependency "rho-acp"
end
