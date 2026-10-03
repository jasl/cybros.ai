require_relative "lib/rho/web-tools/version"

Gem::Specification.new do |spec|
  spec.name = "rho-web-tools"
  spec.version = Rho::WebTools::VERSION

  spec.authors = ["jasl"]
  spec.email = ["jasl9187@hotmail.com"]

  spec.summary = "A web reader for rho's agent loop: web_fetch {url}, as an extension."
  spec.description = "rho-web-tools gives a model running through rho one tool, `web_fetch {url}`: a GET of a " \
    "public http(s) URL through httpx with its SSRF filter and same-site redirects under one " \
    "deadline, HTML rendered to markdown, the head answered under the runner's truncation caps " \
    "with bash's own spill footer and the rest paged through `read`; an image or other binary is " \
    "saved to a file the model can read. It is a separate gem in the runner's shape because the " \
    "gem boundary is the seam — a tools-provider process hosts the same client and render behind " \
    "the SDK's executor door with the adapter's `ToolEnv` lines changed — and because nothing " \
    "here loads until settings.json names it."
  spec.homepage = "https://github.com/jasl/cybros.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/agents/rho/rho-web-tools"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
  # THE LOADER'S CONTRACT: a gem the operator names in `extensions` is
  # required and its module answers `register(api)`. Installed is not
  # wanted: nothing here is loaded until the settings say so.
  spec.metadata["rho_extensions"] = "rho/web-tools"

  spec.require_paths = ["lib"]
  spec.files = Dir.glob("**/*", base: __dir__).reject do |f|
    File.directory?(File.join(__dir__, f)) ||
      (f == File.basename(__FILE__)) ||
      f.end_with?(".gem") ||
      f.start_with?(*%w[Gemfile bin pkg test tmp]) ||
      (f.end_with?(".md") && f != "README.md")
  end

  # `Result`, `Truncation`, `ToolEnv`, `ExecutionContext`, the `register(api)`
  # door; httpx and `CybrosAgent::HttpDeadline` arrive through it (the SDK).
  spec.add_dependency "rho-runner"
  # RUBY'S TURNDOWN: a hand-written HTML-to-markdown converter would be a
  # second implementation of a standard with a battle-tested one
  # available. Its one runtime dependency is nokogiri — Rails' own HTML
  # parser, precompiled for the installer's four platforms. Pinned to the
  # major because `ReverseMarkdown.config` is written once at load and a
  # renamed option must fail at the pin, not silently at a render.
  spec.add_dependency "reverse_markdown", "~> 3.0"
end
