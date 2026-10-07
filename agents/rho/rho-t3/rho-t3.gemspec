require_relative "lib/rho/t3/version"

Gem::Specification.new do |spec|
  spec.name = "rho-t3"
  spec.version = Rho::T3::VERSION
  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]
  spec.summary = "Task-owned native coding delegation through T3's authenticated Effect RPC."
  spec.description = "An optional rho extension that delegates coding to an independently installed T3 service, " \
    "persists continuation handles in Nexus, relays questions and stops, and returns native results and diffs."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"
  spec.metadata["rho_extensions"] = "rho/t3"
  spec.metadata["rho_extension_manifest"] = "rho-extension.json"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-t3"
  spec.require_paths = ["lib"]
  spec.files = Dir["lib/**/*", "sig/**/*", "README.md", "LICENSE.txt", "rho-extension.json"]
  spec.add_dependency "async-http", "~> 0.90"
  spec.add_dependency "async-websocket", "~> 0.30"
  spec.add_dependency "rho"
  spec.add_dependency "rho-runner"
end
