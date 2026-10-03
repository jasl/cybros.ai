require_relative "lib/rho/version"

Gem::Specification.new do |spec|
  spec.name = "rho"
  spec.version = Rho::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "The flagship Cybros agent application: a connected-identity daemon and its CLI."
  spec.description = "Rho is the flagship agent application for the Nexus kernel. The gem carries the daemon body — lifecycle, credential vault, device-flow connection, and the local protocol surface — as a library, plus the single `rho` entry point whose subcommands dispatch onto it."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/agents/rho/rho/README.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.bindir = "exe"
  spec.executables = ["rho"]
  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(
        *%w[Gemfile bin pkg test tmp]
      ) ||
      (f.end_with?(".md") && f != "README.md")
  end

  spec.add_dependency "cybros_agent"
  spec.add_dependency "cmctl", "~> 0.1"
  # COMPOSED, NOT CONTAINED: the runner is its own gem so it can also run
  # with no daemon around it. rho builds one and spawns it on its reactor.
  spec.add_dependency "rho-runner"
  # The CLI dispatcher. exe/rho is the one human entry point
  # and its verb set grows with the product; Thor is what keeps that cheap.
  spec.add_dependency "thor", "~> 1.4"
  # The local control surface. Pure Ruby and thread-based, so the gem installs
  # without a compiler and matches the shell's threads-not-reactor model.
  # The local surface runs on a fiber reactor: long-lived connections
  # (streaming, WebSocket) must not each pin a thread, and remote access
  # wants in-process TLS. async-http and not falcon —
  # rho owns its own router, static serving, Host check and JSON
  # rendering, so Rack would sit underneath all of it doing nothing.
  spec.add_dependency "async-http", "~> 0.90"
  # The gem's realtime client is opt-in and CONSUMER-SUPPLIED:
  # nothing in `cybros_agent` requires it, and a program that follows a run
  # over HTTP needs none of it. rho asks for the socket, so rho declares the
  # stack — which is also why `async` never had to become the gem's problem.
  spec.add_dependency "async-websocket", "~> 0.30"
  # THE BOOT ACCELERATOR (wired as Homebrew wires it):
  # a load-path index and an iseq cache under `$RHO_HOME/cache/bootsnap`,
  # ≈70 ms off every verb. A gemspec dependency and not the portable
  # Ruby's own copy, because rho also runs on rbenv and in the image, and a
  # guarded require that silently finds nothing on two of three installs
  # is a cache nobody noticed was off. `Rho::Boot` never lets it block a
  # boot: absent, unwritable or broken, rho loads uncached.
  spec.add_dependency "bootsnap", "~> 1.26"
end
