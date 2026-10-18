require_relative "lib/rho/browser/version"

Gem::Specification.new do |spec|
  spec.name = "rho-browser"
  spec.version = Rho::Browser::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "A browser for rho's agent loop: six tools over Playwright, as an extension."
  spec.description = "rho-browser gives a model running through rho a real browser — snapshot, " \
    "navigate, click, type, screenshot, evaluate — as an ordinary rho extension. It is a " \
    "separate gem because a browser is a heavy, optional dependency that must never arrive " \
    "on a machine that only asked for a coding runner, and because the extension plane's " \
    "first outside-shaped consumer is the only proof the plane works."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-browser"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  # THE LOADER'S CONTRACT: a gem the operator names in `extensions` is
  # required and its module answers `register(api)`. This key is how
  # `Loader.available` answers "installed" — which is a different question
  # from "wanted", and nothing here is loaded until the settings say so.
  spec.metadata["rho_extensions"] = "rho/browser"

  spec.metadata["rho_extension_manifest"] = "rho-extension.json"
  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (f.end_with?(".md") && f != "README.md")
  end

  spec.add_dependency "rho-runner"
  # PINNED TO THE MINOR, because the Ruby client tracks the Node driver's
  # protocol release for release (`Playwright::COMPATIBLE_PLAYWRIGHT_VERSION`)
  # and a driver a minor ahead or behind is not a supported pair.
  spec.add_dependency "playwright-ruby-client", "~> 1.62.0"
end
