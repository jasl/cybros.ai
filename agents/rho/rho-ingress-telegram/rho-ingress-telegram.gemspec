require_relative "lib/rho/ingress-telegram/version"

Gem::Specification.new do |spec|
  spec.name = "rho-ingress-telegram"
  spec.version = Rho::IngressTelegram::VERSION
  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]
  spec.summary = "Telegram messaging ingress for rho."
  spec.description = "A Telegram extension for rho with a long-polling Bot API client, " \
    "bounded message rendering and per-bot delivery pacing."
  spec.homepage = "https://github.com/jasl/cybros.ai2"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-ingress-telegram"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["rho_extensions"] = "rho/ingress-telegram"
  spec.require_paths = ["lib"]
  spec.files = Dir.glob("{lib,sig}/**/*", base: __dir__).select do |path|
    File.file?(File.join(__dir__, path))
  end + %w[README.md LICENSE.txt]

  spec.add_dependency "rho", "~> 0.1"
  spec.add_dependency "telegram-bot-ruby", "~> 2.8.1"
  spec.add_dependency "httpx", "~> 1.8", ">= 1.8.4"
  spec.add_dependency "kramdown", "~> 2.5", ">= 2.5.2"
  spec.add_dependency "kramdown-parser-gfm", "~> 1.1"
end
