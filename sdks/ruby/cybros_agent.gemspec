require_relative "lib/cybros_agent/version"

Gem::Specification.new do |spec|
  spec.name = "cybros_agent"
  spec.version = CybrosAgent::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "Ruby SDK for agent programs that connect to and call Nexus."
  spec.description = "CybrosAgent is the Ruby SDK for agent applications and runners that talk to the Nexus kernel. The current surface is the typed OAuth device-flow client with durable credential rotation, the bootstrap profile/executor resources, and the member-plane Workspace resources with their nested store entries."
  spec.homepage = "https://github.com/jasl/cybros-ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/sdks/ruby"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/sdks/ruby/README.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

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

  # The one runtime dependency: the default DeviceFlow transport. A consumer
  # that injects its own transport does not exercise it.
  # 1.8.1 is the FLOOR, not 1.8: the absolute-deadline hook the transport
  # relies on landed there, and `~> 1.8` alone admitted a build without it.
  spec.add_dependency "httpx", "~> 1.8", ">= 1.8.1"
end
