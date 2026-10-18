require_relative "lib/cybros_control/version"

Gem::Specification.new do |spec|
  spec.name = "cmctl"
  spec.version = CybrosControl::VERSION
  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]
  spec.summary = "Operator command line for Nexus model configuration."
  spec.description = "A thin Human operator client for Nexus sessions, provider credentials, model availability and account cost-unit configuration."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["cmctl"]
  spec.files = Dir.glob("{lib,exe}/**/*", base: __dir__).select do |path|
    File.file?(File.join(__dir__, path))
  end + %w[README.md LICENSE.md]
  spec.add_dependency "cybros_agent", "~> 0.1"
end
