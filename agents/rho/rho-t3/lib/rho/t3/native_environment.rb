require "fileutils"

module Rho
  module T3
    # Native programs own these files. rho seeds a new local installation once,
    # then leaves provider settings and login rotation to their native owners.
    NativeEnvironment = Data.define(:root, :work_root) do
      PROVIDER_VARIABLES = %w[OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN].freeze

      def self.for(home)
        new(root: home.plugin_root(NAME), work_root: home.work_root)
      end

      def server_root = File.join(root, "server")
      def codex_root = File.join(root, "codex")
      def claude_root = File.join(root, "claude")
      def environment_path = File.join(root, "rho.env")

      def environment(current = ENV.to_h)
        Runner::ChildEnv.scrubbed(current).merge(current.slice(*PROVIDER_VARIABLES)).merge(
          "CODEX_HOME" => codex_root, "CLAUDE_CONFIG_DIR" => claude_root,
          "ANTHROPIC_CONFIG_DIR" => File.join(claude_root, "anthropic")
        )
      end

      def prepare
        [root, server_root, codex_root, claude_root].each do |directory|
          FileUtils.mkdir_p(directory, mode: 0o700)
        end
        FileUtils.mkdir_p(work_root)
        StateFile.new(File.join(server_root, "userdata", "settings.json")).create_once(
          "providerInstances" => {
            "codex" => { "driver" => "codex", "enabled" => true,
              "config" => { "setupMode" => "existing", "binaryPath" => "codex", "homePath" => codex_root } },
            "claudeAgent" => { "driver" => "claudeAgent", "enabled" => true,
              "config" => { "binaryPath" => "claude", "homePath" => claude_root } },
          }
        )
        self
      end

      def installed
        paths = environment.fetch("PATH", "").split(File::PATH_SEPARATOR)
        %w[t3 codex claude].to_h do |program|
          [program, paths.any? { |directory| File.executable?(File.join(directory, program)) && !File.directory?(File.join(directory, program)) }]
        end
      end
    end
  end
end
