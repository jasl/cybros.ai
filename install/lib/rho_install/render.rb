require_relative "manifest"

module RhoInstall
  # A standalone distribution assembled from small owning source files and
  # the manifest. The delivered script needs no Ruby or sibling source files.
  module Render
    module_function

    def run(manifest = Manifest.load)
      File.write(Manifest::SHELL_PATH, manifest.shell)
      File.write(Manifest::INSTALLER_PATH, installer(manifest))
      [Manifest::SHELL_PATH, Manifest::INSTALLER_PATH]
    end

    def installer(manifest)
      source("header") + manifest.shell + manifest.json_block +
        %w[bootstrap packages launchers lifecycle].map { |name| source(name) }.join
    end

    def source(name)
      File.read(File.join(Manifest::ROOT, "src", "#{name}.sh"), encoding: "UTF-8")
    end

    # What `check` reports: each stale file, or nothing.
    def stale(manifest = Manifest.load)
      problems = []
      problems << "install/manifest.sh" unless File.exist?(Manifest::SHELL_PATH) && File.read(Manifest::SHELL_PATH) == manifest.shell
      problems << "install/install.sh" unless File.exist?(Manifest::INSTALLER_PATH) &&
        File.read(Manifest::INSTALLER_PATH, encoding: "UTF-8") == installer(manifest)
      problems
    end
  end
end
