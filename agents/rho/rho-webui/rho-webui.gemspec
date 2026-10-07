require_relative "lib/rho/webui/version"

Gem::Specification.new do |spec|
  spec.name = "rho-webui"
  spec.version = Rho::Webui::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "The browser interface for rho's daemon."
  spec.description = "rho-webui packages the browser interface as a rho extension. " \
    "The daemon serves its HTML, CSS and JavaScript through the existing local control " \
    "surface; the browser uses the console-code handoff and authenticated control APIs. " \
    "Installation and serving require no JavaScript runtime or asset build."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-webui"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/agents/rho/rho-webui/README.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["rho_extensions"] = "rho/webui"
  spec.metadata["rho_extension_manifest"] = "rho-extension.json"

  spec.require_paths = ["lib"]
  spec.files = Dir.glob("{lib,sig,webui}/**/*", base: __dir__).select do |path|
    File.file?(File.join(__dir__, path))
  end + %w[README.md LICENSE.txt rho-extension.json]

  # Registration uses the daemon's API, not the standalone runner's tool API.
  spec.add_dependency "rho", "~> 0.1"
end
