require "open3"

module Rho
  module T3
    # Operator setup uses the native CLI and finite public project API. It does
    # not infer a project from T3's database or start a coding assignment.
    class Setup
      def self.register(api, settings:, native:)
        api.register_command("t3", usage: "t3 ACTION [VALUE]",
          description: "Check T3, select a project or sign in to a local coding agent",
          options: { "api-key": { type: :boolean, default: false, desc: "Read a Codex API key from stdin" } }) do |cli, arguments, options|
          new(cli: cli, settings: settings, native: native).run(*arguments, api_key: options[:"api-key"])
        end
      end

      def initialize(cli:, settings:, native:, bridge: Bridge.new(settings))
        @cli, @settings, @native, @bridge = cli, settings, native, bridge
      end

      def run(action = "status", value = nil, api_key: false)
        result = case action
        when "status" then status
        when "check" then check
        when "projects" then projects
        when "project" then select_project(value)
        when "create" then create_project(value)
        when "token" then return issue_token
        when "login" then return login(value, api_key: api_key)
        else raise Error, "Use rho t3 status|check|projects|project ID|create PATH|token|login codex|login claude"
        end
        @cli.out.puts(JSON.pretty_generate(result))
        result
      end

      def status
        { "server" => @settings.server, "url" => @settings.url, "project_id" => @settings.project_id,
          "configured" => @settings.configured?, "issues" => @settings.issues,
          "installed" => @settings.local? ? @native.installed : nil,
          "native_configuration" => @settings.local? ? @native.root : nil }.compact
      end

      def check
        @settings.require_connection
        configuration = @bridge.call("server.getConfig", {})
        selected = projects.any? { |project| project.fetch("id") == @settings.project_id }
        status.merge("service" => { "authenticated" => true, "orchestration_protocol" => 2 },
          "project_available" => selected, "providers" => Catalog.new(providers: configuration.fetch("providers")).report)
      end

      def projects
        @bridge.projects.map do |project|
          row = project.to_h
          { "id" => row.fetch("id").to_s, "title" => row.fetch("title").to_s,
            "workspaceRoot" => row.fetch("workspaceRoot").to_s }
        end
      rescue KeyError, NoMethodError, TypeError
        raise Error, "T3 returned an incomplete project directory", cause: nil
      end

      def select_project(id)
        project = projects.find { |row| row.fetch("id") == id }
        raise Error, "Choose a project id returned by rho t3 projects" unless project

        save_project(project)
      end

      def create_project(path)
        path = path.to_s.strip
        raise Error, "Provide an absolute project path in T3's execution environment" unless path.start_with?("/")

        existing = project_at(path)
        return save_project(existing) if existing

        begin
          created = @bridge.create_project(path: path, title: File.basename(path))
        rescue Uncertain
          created = project_at(path)
          raise Uncertain, "T3 project creation was not confirmed; inspect rho t3 projects before creating again", cause: nil unless created
        end
        save_project(created)
      end

      def issue_token
        require_local
        @native.prepare
        token, _error, status = Open3.capture3(@native.environment, "t3", "auth", "session", "issue",
          "--base-dir", @native.server_root, "--label", "rho", "--token-only", unsetenv_others: true)
        token = token.strip
        unless status.success? && token.match?(/\A[A-Za-z0-9._~-]{1,8192}\z/)
          raise Error, "Native T3 bearer issuance failed; inspect the native installation"
        end
        @cli.out.puts(token)
        nil
      rescue Errno::ENOENT
        raise Error, "The native T3 executable is not installed", cause: nil
      end

      def login(provider, api_key: false)
        require_local
        @native.prepare
        command = case provider
        when "codex"
          ["codex", "-c", 'cli_auth_credentials_store="file"', "login", api_key ? "--with-api-key" : "--device-auth"]
        when "claude"
          raise Error, "For Claude API access, configure ANTHROPIC_API_KEY in the private rho environment file" if api_key

          ["claude", "auth", "login"]
        else raise Error, "Choose codex or claude for native login"
        end
        exec(@native.environment, *command, chdir: @native.work_root, unsetenv_others: true)
      end

      private

        def save_project(project)
          id = project.fetch("id").to_s
          @cli.core.configure_extension(NAME, operations: [{ "op" => "set", "path" => ["project_id"], "value" => id }])
        end

        def project_at(path)
          matches = projects.select { |project| project.fetch("workspaceRoot") == path }
          raise Error, "Several T3 projects use this path; choose one with rho t3 project ID" if matches.length > 1

          matches.first
        end

        def require_local
          raise Error, "Run native login and bearer issuance on the host that owns T3 in host mode" unless @settings.local?
        end
    end
  end
end
