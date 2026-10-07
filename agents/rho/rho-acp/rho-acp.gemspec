require_relative "lib/rho/acp/version"

Gem::Specification.new do |spec|
  spec.name = "rho-acp"
  spec.version = Rho::Acp::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "rho as an ACP agent: the protocol layer and the `rho-acp` process an editor spawns."
  spec.description = "rho-acp is the Agent Client Protocol on rho, agent side: the wire (ndjson framing, " \
    "JSON-RPC ids both directions, `$/cancel_request`, the error codes, the method names) and the " \
    "process an editor, the registry or harbor spawns — `rho-acp` on stdio, a PEER SURFACE over " \
    "`Rho::Core` beside the CLI and the WebUI, never an extension. It is a separate gem because a " \
    "surface is a distribution's choice, not a daemon's: the daemon owns the conversation, and " \
    "this process speaks for it through session lifecycle, prompt streaming, authentication, " \
    "configuration and cancellation methods."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-acp"
  spec.metadata["documentation_uri"] =
    "#{spec.homepage}/blob/main/agents/rho/rho-acp/README.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  # NOT AN EXTENSION: no `rho_extensions` metadata, no `register(api)`.
  # An editor spawns `rho-acp`; rho's settings never name this gem.

  spec.bindir = "exe"
  spec.executables = ["rho-acp"]
  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (f.end_with?(".md") && f != "README.md")
  end

  # The body it speaks for: `Rho::Core` (the primitives over the daemon's
  # routes), `Rho::Cli::Connect` (the ceremony the auth method runs),
  # `Rho::Locale`. The runner and the SDK arrive through rho.
  spec.add_dependency "rho"
end
