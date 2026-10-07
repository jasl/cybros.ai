require_relative "lib/rho/dev/version"

Gem::Specification.new do |spec|
  spec.name = "rho-dev"
  spec.version = Rho::Dev::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "rho's development extension: the verbs that operate a conversation from a terminal."
  spec.description = "rho-dev carries the verbs that operate a conversation from a terminal — open one and return " \
    "its ids, say a second turn, stop it, watch or follow a run, read its result, transcript, graph and sealed " \
    "request, decide a held call, repair a halted run, rewind, regenerate, the skills and the access carrier — " \
    "for the orchestrator, e2e and other agents to test and debug through. Every verb is a thin formatter over " \
    "`Rho::Core`'s primitives, loaded through the same extension door as any operator gem. It is never in the " \
    "distribution: a product install carries the management verbs and `run`; a home that names `rho/dev` in " \
    "its settings, with this gem's `lib` on the load path, has the rest."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-dev"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  # Static metadata makes this opt-in plugin discoverable before registration.
  spec.metadata["rho_extensions"] = "rho/dev"
  spec.metadata["rho_extension_manifest"] = "lib/rho/dev_plugin.json"

  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (f.end_with?(".md") && f != "README.md")
  end

  # The core it formats: `Rho::Core`'s primitives, `Rho::Cli::Terminal`'s
  # renderers, `Rho::Until.fold`, the runner's skill parser.
  spec.add_dependency "rho"
end
