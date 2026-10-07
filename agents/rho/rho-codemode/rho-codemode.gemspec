require_relative "lib/rho/codemode/version"

Gem::Specification.new do |spec|
  spec.name = "rho-codemode"
  spec.version = Rho::Codemode::VERSION
  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]
  spec.summary = "JavaScript authoring and live task orchestration for rho."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["rho_extensions"] = "rho/codemode"
  spec.metadata["rho_extension_manifest"] = "rho-extension.json"
  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |file|
    File.directory?(File.join(__dir__, file)) || file == File.basename(__FILE__) ||
      file.end_with?(".gem") || file.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (file.end_with?(".md") && file != "README.md")
  end
  spec.add_dependency "rho-runner"
  spec.add_dependency "mini_racer", "~> 0.22.1"
end
