require_relative "lib/rho/env/version"

Gem::Specification.new do |spec|
  spec.name = "rho-env"
  spec.version = Rho::Env::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "Embedded tool execution and environment library for rho."
  spec.description = "Filesystem and process tools, checkpoints, and an executor inbox loop. " \
    "The rho application supplies credentials, configuration, and resource lifetimes."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-env"
  spec.metadata["documentation_uri"] =
    "#{spec.homepage}/blob/main/agents/rho/rho-env/README.md"
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
  # Each fixed execution thread hosts waiting handlers as cooperative fibers.
  spec.add_dependency "async", "~> 2.46.0"
  # The schemas a tool declares are MCP `inputSchema` — JSON Schema in the
  # wild — and every call is validated against its own before the handler
  # runs. A subset validator would be a second implementation
  # of a standard with a battle-tested one available.
  spec.add_dependency "json_schemer", "~> 2.4"
  spec.add_dependency "sqlite3", "~> 2.10"
end
