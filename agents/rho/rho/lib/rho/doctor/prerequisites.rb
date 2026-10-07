module Rho
  module Doctor
    # The table `install.sh` checked before it planned, repeated after: what rho's tools and the next `rho update`
    # need from the host, never installed by rho.
    module Prerequisites
      GIT_MINIMUM = Gem::Version.new("2.7.0")
      BASH = "/bin/bash".freeze

      module_function

      # The previewers Active Storage looks for on the host that serves an
      # upload's thumbnail or preview: poppler's `pdftoppm` for a
      # PDF's page, `ffmpeg` for a video's frame. Reported, never required:
      # without them the kernel answers the typed refusal for those kinds.
      PREVIEWERS = { "pdftoppm" => "-v", "ffmpeg" => "-version" }.freeze

      def call(context)
        [git, bash, fetcher, tar, compiler(context), previewers(context)]
      end

      def git
        line = Doctor.version_line("git", "--version")
        return Row.new("prerequisites", "git", :fail, "missing (the environment document and every coding task need it)") unless line

        version = line[/\d+\.\d+(\.\d+)?/]
        if version && Gem::Version.new(version) < GIT_MINIMUM
          Row.new("prerequisites", "git", :fail, "#{version} is older than #{GIT_MINIMUM}")
        else
          Row.new("prerequisites", "git", :ok, version.to_s)
        end
      end

      def bash
        return Row.new("prerequisites", "bash", :ok, BASH) if File.executable?(BASH)

        Row.new("prerequisites", "bash", :fail, "#{BASH} is missing (the bash tool's shell)")
      end

      def fetcher
        %w[curl wget].each do |name|
          line = Doctor.version_line(name, "--version")
          return Row.new("prerequisites", "curl", :ok, line.to_s.split[0, 2].join(" ")) if line
        end
        Row.new("prerequisites", "curl", :fail, "neither curl nor wget is on PATH (`rho update` downloads with one)")
      end

      def tar
        line = Doctor.version_line("tar", "--version")
        line ? Row.new("prerequisites", "tar", :ok, line.split[0, 2].join(" ")) : Row.new("prerequisites", "tar", :fail, "missing")
      end

      # Reported, required only by `rho update` (a Ruby or rho row change
      # rebuilds the native extensions).
      def compiler(context)
        cc = Doctor.version_line("cc", "--version")
        make = Doctor.version_line("make", "--version")
        return Row.new("prerequisites", "compiler", :ok, "#{cc.to_s.split(" (").first}; #{make}") if cc && make

        Row.new("prerequisites", "compiler", :warn, "no cc and make on PATH: `rho update` cannot rebuild gems (#{hint(context)})")
      end

      def hint(context)
        darwin?(context) ? "xcode-select --install" : "apt install build-essential"
      end

      def previewers(context)
        path = context.env.fetch("PATH") { ENV.fetch("PATH", "") }
        lines = PREVIEWERS.to_h do |name, flag|
          executable = Doctor.on_path(name, path)
          [name, executable && Doctor.version_line(executable, flag)]
        end
        found, missing = lines.partition { |_name, line| line }
        detail = found.map { |name, line| "#{name} #{line[/\d+(\.\d+)+/] || line}" }.join("; ")
        return Row.new("prerequisites", "previewers", :ok, detail) if missing.empty?

        Row.new("prerequisites", "previewers", :warn,
          "no #{missing.map(&:first).join(" or ")} on PATH: a PDF's or a video's thumbnail and preview answer " \
          "representation_unavailable (#{previewer_hint(context)})#{"; #{detail}" unless detail.empty?}")
      end

      # Homebrew's names on a Mac, apt's on Linux — the image's manifest rows.
      def previewer_hint(context)
        darwin?(context) ? "brew install poppler ffmpeg" : "apt install poppler-utils ffmpeg"
      end

      def darwin?(context)
        platform = context.receipt&.fetch("platform", nil).to_s
        platform.start_with?("darwin") || RUBY_PLATFORM.include?("darwin")
      end
    end
  end
end
