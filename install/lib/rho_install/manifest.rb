require "json"

module RhoInstall
  # `install/manifest.json` as an object, and its two renderings: the shell
  # block `install.sh` carries (bash 3.2 has no JSON; every row becomes a
  # variable) and the canonical JSON the prefix's `manifest.json` is
  # written from. `rake install:render` writes them; `rake install:check`
  # refuses a stale copy.
  class Manifest
    # `RHO_INSTALL_ROOT` lets the shell tests run the pair against a copy.
    ROOT = ENV.fetch("RHO_INSTALL_ROOT") { File.expand_path("../..", __dir__) }
    JSON_PATH = File.join(ROOT, "manifest.json")
    SHELL_PATH = File.join(ROOT, "manifest.sh")
    INSTALLER_PATH = File.join(ROOT, "install.sh")

    SHELL_BEGIN = "# >>> rho manifest (rendered from install/manifest.json by `rake install:render`; do not edit by hand)".freeze
    SHELL_END = "# <<< rho manifest".freeze
    JSON_BEGIN = "# >>> rho manifest.json (the same document, verbatim, for the prefix's copy and `rho doctor`)".freeze
    JSON_END = "# <<< rho manifest.json".freeze
    HEREDOC = "RHO_MANIFEST_JSON_EOF".freeze

    attr_reader :data

    def self.load(path = JSON_PATH) = new(JSON.parse(File.read(path, encoding: "UTF-8")))

    def initialize(data)
      @data = data
    end

    def json = "#{JSON.pretty_generate(data)}\n"

    # Variable names carry the manifest's keys with `-` and `.` as `_`.
    def self.key(name) = name.to_s.tr("-.", "__")

    def shell
      # Every variable is read by indirect expansion (`${!name}`), which
      # shellcheck cannot follow.
      lines = [SHELL_BEGIN, "# shellcheck disable=SC2034"]
      lines.concat(app_lines, runtime_lines, tool_lines, apt_lines, toolchain_lines)
      lines << SHELL_END
      "#{lines.join("\n")}\n"
    end

    def json_block
      [JSON_BEGIN, "RHO_MANIFEST_JSON=$(cat <<'#{HEREDOC}'", json.chomp, HEREDOC, ")", JSON_END].join("\n") + "\n"
    end

    private

      def assign(name, value) = %(#{name}="#{Array(value).join(" ").gsub('"', '\\"')}")

      def app_lines
        app = data.fetch("app")
        [
          assign("RHO_MANIFEST_VERSION", data.fetch("manifest_version")),
          assign("RHO_MANIFEST_GENERATED", data.fetch("generated")),
          assign("RHO_PLATFORMS", data.fetch("platforms")),
          assign("RHO_PROFILES", data.fetch("profiles").keys),
          assign("RHO_APP_TREES", app.fetch("trees")),
          assign("RHO_APP_ENTRY", app.fetch("entry")),
          assign("RHO_APP_GEMFILE", app.fetch("gemfile")),
          assign("RHO_APP_BUNDLE_WITHOUT", app.fetch("bundle_without")),
        ]
      end

      def runtime_lines
        runtime = data.fetch("runtime")
        header = runtime.fetch("headers").map { |name, value| "#{name}: #{value}" }.first
        lines = [
          assign("RHO_RUBY_VERSION", runtime.fetch("version")),
          assign("RHO_RUBY_BUNDLER", runtime.fetch("bundler")),
          assign("RHO_RUBY_HEADER", header),
        ]
        runtime.fetch("artifacts").each do |platform, artifact|
          prefix = "RHO_RUBY_#{self.class.key(platform)}"
          lines << assign("#{prefix}_TAG", artifact.fetch("tag"))
          lines << assign("#{prefix}_FILENAME", artifact.fetch("filename"))
          lines << assign("#{prefix}_URL", artifact.fetch("url"))
          lines << assign("#{prefix}_SHA256", artifact.fetch("sha256"))
          lines << assign("#{prefix}_BYTES", artifact.fetch("bytes"))
        end
        lines
      end

      def tool_lines
        tools = data.fetch("tools")
        lines = [assign("RHO_TOOLS", tools.keys.map { |name| self.class.key(name) })]
        tools.each do |name, row|
          prefix = "RHO_TOOL_#{self.class.key(name)}"
          lines << assign("#{prefix}_NAME", name)
          lines << assign("#{prefix}_VERSION", row.fetch("version"))
          lines << assign("#{prefix}_PROFILES", row.fetch("profiles"))
          lines << assign("#{prefix}_INTO", row.fetch("into"))
          lines << assign("#{prefix}_UNPACK", row.fetch("unpack"))
          lines << assign("#{prefix}_COMMAND", row.fetch("command")) if row.key?("command")
          row.fetch("artifacts", {}).each do |platform, artifact|
            lines << assign("#{prefix}_#{self.class.key(platform)}_URL", artifact.fetch("url"))
            lines << assign("#{prefix}_#{self.class.key(platform)}_SHA256", artifact.fetch("sha256"))
            lines << assign("#{prefix}_#{self.class.key(platform)}_MEMBERS", artifact.fetch("members"))
          end
        end
        lines
      end

      def apt_lines
        apt = data.fetch("apt")
        chromium = apt.fetch("chromium").reject { |key, _| key == "provenance" }
        lines = [
          assign("RHO_APT_PREREQUISITES", apt.fetch("prerequisites")),
          assign("RHO_BREW_PREREQUISITES", data.fetch("brew").fetch("prerequisites")),
          assign("RHO_APT_CHROMIUM_DISTROS", chromium.keys.map { |distro| self.class.key(distro) }),
        ]
        chromium.each { |distro, packages| lines << assign("RHO_APT_CHROMIUM_#{self.class.key(distro)}", packages) }
        lines
      end

      # The image's layer (install/docker/Dockerfile sources manifest.sh in
      # its RUN steps, so it carries no version or package name of its own).
      def toolchain_lines
        toolchains = data.fetch("toolchains")
        mise = toolchains.fetch("mise")
        gh = toolchains.fetch("gh")
        lines = [
          assign("RHO_APT_IMAGE", data.fetch("apt").fetch("image").fetch("packages")),
          assign("RHO_APT_COWORK", data.fetch("apt").fetch("cowork").fetch("packages")),
          assign("RHO_IMAGE_BASE", toolchains.fetch("base")),
          assign("RHO_COWORK_PYTHON", toolchains.fetch("cowork_python")),
          assign("RHO_TOOLCHAIN_MISE_VERSION", mise.fetch("version")),
          assign("RHO_TOOLCHAIN_MISE_RUBY_COMPILE", mise.fetch("ruby_compile")),
          assign("RHO_TOOLCHAIN_MISE_INTO", mise.fetch("into")),
          assign("RHO_TOOLCHAIN_MISE_TOOLS", mise.fetch("tools")),
          assign("RHO_TOOLCHAIN_NPM_DEFAULT_PACKAGES", mise.fetch("npm_default_packages")),
          assign("RHO_TOOLCHAIN_UV_PYTHON", toolchains.fetch("uv_python")),
          assign("RHO_TOOLCHAIN_UV_TOOLS", toolchains.fetch("uv_tools")),
          assign("RHO_TOOLCHAIN_GH_VERSION", gh.fetch("version")),
          assign("RHO_TOOLCHAIN_GH_INTO", gh.fetch("into")),
          assign("RHO_TOOLCHAIN_TINI_VERSION", toolchains.fetch("tini").fetch("version")),
        ]
        { "MISE" => mise, "GH" => gh }.each do |name, row|
          row.fetch("artifacts").each do |platform, artifact|
            prefix = "RHO_TOOLCHAIN_#{name}_#{self.class.key(platform)}"
            lines << assign("#{prefix}_URL", artifact.fetch("url"))
            lines << assign("#{prefix}_SHA256", artifact.fetch("sha256"))
            lines << assign("#{prefix}_MEMBERS", artifact.fetch("members"))
          end
        end
        lines
      end
  end
end
