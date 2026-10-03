require_relative "lib/rho/runner/version"

Gem::Specification.new do |spec|
  spec.name = "rho-runner"
  spec.version = Rho::Runner::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "The passive runner: parked tool work from a Nexus kernel, executed locally."
  spec.description = "rho-runner takes tool work a Nexus agent loop parked for a runner, " \
    "executes it on this machine, and answers. It is PASSIVE by construction — it dials " \
    "out and is never dialled into — so it runs on an intranet with no public address. " \
    "The flagship `rho` daemon composes it; it is a separate gem because a runner must " \
    "also be able to run alone."
  spec.homepage = "https://github.com/jasl/cybros-ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-runner"
  spec.metadata["documentation_uri"] =
    "#{spec.homepage}/blob/main/agents/rho/rho-runner/README.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (f.end_with?(".md") && f != "README.md")
  end

  # The SDK: a runner needs one HTTP client and the typed doors.
  spec.add_dependency "cybros_agent"
  # The schemas a tool declares are MCP `inputSchema` — JSON Schema in the
  # wild — and every call is validated against its own before the handler
  # runs. A subset validator would be a second implementation
  # of a standard with a battle-tested one available.
  spec.add_dependency "json_schemer", "~> 2.4"
end
