require "digest"
require "json"
require "net/http"
require "tmpdir"
require "uri"
require_relative "manifest"

module RhoInstall
  # `rake install:bump`: refresh every row from its
  # publisher and write the sha256 that was verified or computed —
  # Homebrew's four `portable-ruby-*` files at brew HEAD (never the local
  # brew), the GitHub release APIs of ripgrep / fd / jq / uv, nodejs.org's
  # index and SHASUMS256.txt, the gem's `COMPATIBLE_PLAYWRIGHT_VERSION` and
  # the registry tarball, the Chromium apt lists from playwright-core's own
  # native-dependency table, the image's mise and gh from their release
  # checksum files, and the image's tool list pinned to full versions by
  # the mise on this machine. Refuses a Ruby rho's gemspec cannot use. A
  # network task, run on a bump, never in CI. The app has no row to bump:
  # its source is the checkout, its version the commit.
  class Bump
    BREW_RAW = "https://raw.githubusercontent.com/Homebrew/brew/HEAD/Library/Homebrew/vendor".freeze
    BREW_FILES = { "darwin-arm64" => "arm64-darwin", "darwin-x64" => "x86_64-darwin",
                   "linux-x64" => "x86_64-linux", "linux-arm64" => "arm64-linux" }.freeze
    GHCR = "https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:".freeze
    RUST_TRIPLES = { "darwin-arm64" => "aarch64-apple-darwin", "darwin-x64" => "x86_64-apple-darwin",
                     "linux-x64" => "x86_64-unknown-linux", "linux-arm64" => "aarch64-unknown-linux" }.freeze
    JQ_NAMES = { "darwin-arm64" => "jq-macos-arm64", "darwin-x64" => "jq-macos-amd64",
                 "linux-x64" => "jq-linux-amd64", "linux-arm64" => "jq-linux-arm64" }.freeze
    NODE_NAMES = { "darwin-arm64" => "darwin-arm64.tar.gz", "darwin-x64" => "darwin-x64.tar.gz",
                   "linux-x64" => "linux-x64.tar.xz", "linux-arm64" => "linux-arm64.tar.xz" }.freeze
    DISTROS = %w[ubuntu26.04 ubuntu24.04 debian13 debian12].freeze
    LINUX_ARCHES = { "linux-x64" => "x64", "linux-arm64" => "arm64" }.freeze
    REPO_ROOT = File.expand_path("../../..", __dir__)

    def initialize(manifest = Manifest.load, out: $stdout)
      @data = manifest.data
      @out = out
    end

    def run
      bump_runtime
      bump_rg
      bump_fd
      bump_jq
      bump_uv
      bump_node
      bump_playwright
      bump_mise
      bump_gh
      bump_toolchain_tools
      @data["generated"] = Time.now.utc.strftime("%Y-%m-%d")
      File.write(Manifest::JSON_PATH, Manifest.new(@data).json)
      Manifest::JSON_PATH
    end

    private

      def say(line) = @out.puts("==> #{line}")

      # Headers are for the first host only (ghcr's bearer must not follow
      # the redirect to its CDN — curl drops it the same way); every call
      # has a timeout, because a bump that hangs teaches nothing.
      def request(kind, url, headers: {}, limit: 5)
        raise "too many redirects: #{url}" if limit.zero?

        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) do |http|
          http.request(kind.new(uri, { "User-Agent" => "rho-install-bump" }.merge(headers)))
        end
        case response
        when Net::HTTPSuccess then response
        when Net::HTTPRedirection
          target = URI.join(url, response["location"]).to_s
          request(kind, target, headers: URI(target).host == uri.host ? headers : {}, limit: limit - 1)
        else raise "#{url}: HTTP #{response.code}"
        end
      end

      def fetch(url, headers: {}) = request(Net::HTTP::Get, url, headers: headers).body.b
      def head(url, headers: {}) = request(Net::HTTP::Head, url, headers: headers)
      def sha256_of(url) = Digest::SHA256.hexdigest(fetch(url))
      def content_length(url, headers: {}) = head(url, headers: headers)["content-length"].to_i

      def latest_tag(repo) = JSON.parse(fetch("https://api.github.com/repos/#{repo}/releases/latest")).fetch("tag_name")

      # `<sha>  <name>` lines, as sha256sum writes them.
      def sums(text) = text.lines.to_h { |line| sha, name = line.split; [name.to_s.sub(/\A\*/, ""), sha] }

      def bump_runtime
        version = fetch("#{BREW_RAW}/portable-ruby-version").strip
        ruby = version.split("_").first
        requirement = Gem::Requirement.new(File.read(File.join(REPO_ROOT, "agents/rho/rho/rho.gemspec"), encoding: "UTF-8")[/required_ruby_version = "([^"]+)"/, 1])
        raise "brew HEAD's portable Ruby #{ruby} does not satisfy rho.gemspec (#{requirement})" unless requirement.satisfied_by?(Gem::Version.new(ruby))

        pinned = File.read(File.join(REPO_ROOT, ".ruby-version"), encoding: "UTF-8").strip
        say "portable-ruby #{version} at brew HEAD#{ruby == pinned ? "" : " (NOTE: .ruby-version is #{pinned}; rho's Ruby follows Homebrew's)"}"
        runtime = @data.fetch("runtime")
        runtime["version"] = version
        runtime["ruby"] = ruby
        runtime["bundler"] = File.read(File.join(REPO_ROOT, "agents/rho/rho/Gemfile.lock"), encoding: "UTF-8")[/^BUNDLED WITH\n\s+(\S+)/, 1]
        header = runtime.fetch("headers").map { |name, value| [name, value] }.to_h
        BREW_FILES.each do |platform, file|
          text = fetch("#{BREW_RAW}/portable-ruby-#{file}")
          tag = text[/ruby_TAG=(\S+)/, 1]
          sha = text[/ruby_SHA=(\S+)/, 1]
          url = "#{GHCR}#{sha}"
          runtime.fetch("artifacts")[platform] = {
            "tag" => tag, "filename" => "portable-ruby-#{version}.#{tag}.bottle.tar.gz",
            "url" => url, "sha256" => sha, "bytes" => content_length(url, headers: header),
          }
        end
      end

      def bump_rg
        tag = latest_tag("BurntSushi/ripgrep")
        say "ripgrep #{tag}"
        row = @data.fetch("tools").fetch("rg")
        row["version"] = tag
        RUST_TRIPLES.each do |platform, triple|
          triple += "-musl" if triple.include?("linux")
          name = "ripgrep-#{tag}-#{triple}"
          url = "https://github.com/BurntSushi/ripgrep/releases/download/#{tag}/#{name}.tar.gz"
          row.fetch("artifacts")[platform] = { "url" => url, "sha256" => fetch("#{url}.sha256").split.first, "members" => ["#{name}/rg"] }
        end
      end

      def bump_fd
        tag = latest_tag("sharkdp/fd")
        say "fd #{tag} (hashing four tarballs)"
        row = @data.fetch("tools").fetch("fd")
        row["version"] = tag.delete_prefix("v")
        RUST_TRIPLES.each do |platform, triple|
          triple += "-musl" if triple.include?("linux")
          name = "fd-#{tag}-#{triple}"
          url = "https://github.com/sharkdp/fd/releases/download/#{tag}/#{name}.tar.gz"
          row.fetch("artifacts")[platform] = { "url" => url, "sha256" => sha256_of(url), "members" => ["#{name}/fd"] }
        end
      end

      def bump_jq
        tag = latest_tag("jqlang/jq")
        say "jq #{tag}"
        row = @data.fetch("tools").fetch("jq")
        row["version"] = tag.delete_prefix("jq-")
        checksums = sums(fetch("https://github.com/jqlang/jq/releases/download/#{tag}/sha256sum.txt"))
        JQ_NAMES.each do |platform, name|
          row.fetch("artifacts")[platform] = {
            "url" => "https://github.com/jqlang/jq/releases/download/#{tag}/#{name}", "sha256" => checksums.fetch(name), "members" => ["jq"],
          }
        end
      end

      def bump_uv
        tag = latest_tag("astral-sh/uv")
        say "uv #{tag}"
        row = @data.fetch("tools").fetch("uv")
        row["version"] = tag
        RUST_TRIPLES.each do |platform, triple|
          triple += "-gnu" if triple.include?("linux")
          name = "uv-#{triple}"
          url = "https://github.com/astral-sh/uv/releases/download/#{tag}/#{name}.tar.gz"
          row.fetch("artifacts")[platform] = { "url" => url, "sha256" => fetch("#{url}.sha256").split.first, "members" => ["#{name}/uv", "#{name}/uvx"] }
        end
      end

      # The newest 24.x with an LTS name — the line the manifest pins.
      def bump_node
        index = JSON.parse(fetch("https://nodejs.org/dist/index.json"))
        release = index.find { |entry| entry["version"].start_with?("v24.") && entry["lts"] } or raise "no Node 24 LTS in the index"
        version = release.fetch("version")
        say "node #{version} (#{release["lts"]})"
        row = @data.fetch("tools").fetch("node")
        row["version"] = version.delete_prefix("v")
        checksums = sums(fetch("https://nodejs.org/dist/#{version}/SHASUMS256.txt"))
        NODE_NAMES.each do |platform, suffix|
          name = "node-#{version}-#{suffix}"
          row.fetch("artifacts")[platform] = { "url" => "https://nodejs.org/dist/#{version}/#{name}", "sha256" => checksums.fetch(name), "members" => [] }
        end
      end

      def bump_playwright
        version = gem_playwright_version
        say "playwright-core #{version} (the gem's constant; hashing the tarball, reading its apt table)"
        row = @data.fetch("tools").fetch("playwright-core")
        row["version"] = version
        row["derived_from"]["value"] = version
        url = "https://registry.npmjs.org/playwright-core/-/playwright-core-#{version}.tgz"
        tarball = fetch(url)
        row["artifacts"]["all"] = { "url" => url, "sha256" => Digest::SHA256.hexdigest(tarball), "members" => [] }
        bundle = Dir.mktmpdir("rho-bump") do |dir|
          File.binwrite(File.join(dir, "playwright-core.tgz"), tarball)
          IO.popen(["tar", "-xzOf", File.join(dir, "playwright-core.tgz"), "package/lib/coreBundle.js"], &:read)
        end
        chromium = @data.fetch("apt").fetch("chromium")
        DISTROS.each { |distro| chromium[distro] = apt_list(bundle, distro) }
      end

      def gem_playwright_version
        Dir.chdir(File.join(REPO_ROOT, "agents/rho/rho-browser")) do
          IO.popen(["bundle", "exec", "ruby", "-e", "require 'playwright/version'; print Playwright::COMPATIBLE_PLAYWRIGHT_VERSION"], &:read)
        end.tap { |version| raise "could not read Playwright::COMPATIBLE_PLAYWRIGHT_VERSION" if version.to_s.empty? }
      end

      def apt_list(bundle, distro)
        start = bundle.index(%("#{distro}-x64")) or raise "playwright-core's table has no #{distro}"
        segment = bundle[start, 6000]
        list = segment[/(?:"chromium"|chromium)\s*:\s*\[([^\]]*)\]/, 1] or raise "no chromium list for #{distro}"
        list.scan(/"([^"]+)"/).flatten
      end

      # The image's toolchain manager: one static binary per Linux arch,
      # its SHASUMS256.txt lines prefixed `./`.
      def bump_mise
        tag = latest_tag("jdx/mise")
        say "mise #{tag}"
        row = @data.fetch("toolchains").fetch("mise")
        row["version"] = tag.delete_prefix("v")
        checksums = sums(fetch("https://github.com/jdx/mise/releases/download/#{tag}/SHASUMS256.txt").gsub("./", ""))
        LINUX_ARCHES.each do |platform, arch|
          name = "mise-#{tag}-linux-#{arch}.tar.gz"
          row.fetch("artifacts")[platform] = {
            "url" => "https://github.com/jdx/mise/releases/download/#{tag}/#{name}", "sha256" => checksums.fetch(name), "members" => ["mise/bin/mise"],
          }
        end
      end

      def bump_gh
        tag = latest_tag("cli/cli")
        version = tag.delete_prefix("v")
        say "gh #{tag}"
        row = @data.fetch("toolchains").fetch("gh")
        row["version"] = version
        checksums = sums(fetch("https://github.com/cli/cli/releases/download/#{tag}/gh_#{version}_checksums.txt"))
        { "linux-x64" => "amd64", "linux-arm64" => "arm64" }.each do |platform, arch|
          name = "gh_#{version}_linux_#{arch}"
          row.fetch("artifacts")[platform] = {
            "url" => "https://github.com/cli/cli/releases/download/#{tag}/#{name}.tar.gz", "sha256" => checksums.fetch("#{name}.tar.gz"), "members" => ["#{name}/bin/gh"],
          }
        end
      end

      # The image's tool list, every `name@version` a FULL version: a
      # `node@24` floats to the latest patch at build time, and a
      # reproducible image wants `node@24.21.0`. Resolved by this machine's
      # mise (`mise ls-remote`), the same resolver the image runs; a full
      # version is kept as written.
      def bump_toolchain_tools
        row = @data.fetch("toolchains").fetch("mise")
        row["tools"] = row.fetch("tools").map { |tool| pinned_tool(tool) }
        say "mise tools: #{row["tools"].join(" ")}"
      end

      def pinned_tool(tool)
        name, version = tool.split("@", 2)
        return tool if version.to_s.count(".") >= 2

        resolved = IO.popen(["mise", "ls-remote", tool], &:read).to_s.split.last
        raise "mise ls-remote #{tool} answered nothing" if resolved.to_s.empty?

        "#{name}@#{resolved}"
      end
  end
end
