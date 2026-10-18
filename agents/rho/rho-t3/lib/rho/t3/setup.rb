require "open3"
require "io/console"

module Rho
  module T3
    # Operator setup uses the native CLI and finite public project API. It does
    # not infer a project from T3's database or start a coding assignment. The
    # directory reads, project choices and the bearer serve the `rho t3`
    # command and the page's routes alike: each caller saves through its own
    # settings owner (`persist:`) and gets back that owner's answer.
    class Setup
      BEARER_PATTERN = /\A[A-Za-z0-9._~-]{1,8192}\z/

      def self.register(api, settings:, native:)
        api.register_command("t3", usage: "t3 ACTION [VALUE]",
          description: "Check T3, save its bearer, select a project or sign in to a local coding agent",
          options: { "api-key": { type: :boolean, default: false, desc: "Read a Codex API key from stdin" } }) do |cli, arguments, options|
          persist = ->(operations:, **) { cli.core.configure_extension(NAME, operations: operations) }
          new(settings: settings, native: native, persist: persist).run(*arguments, out: cli.out, api_key: options[:"api-key"])
        end
      end

      def initialize(settings:, native:, persist:, bridge: Bridge.new(settings), input: $stdin, prompt: $stderr)
        @settings, @native, @persist, @bridge, @input, @prompt = settings, native, persist, bridge, input, prompt
      end

      def run(action = "status", value = nil, out:, api_key: false)
        result = case action
        when "status" then status
        when "check" then check
        when "projects" then projects
        when "project" then select_project(value)
        when "create" then create_project(value)
        when "token" then save_token
        when "login" then return login(value, api_key: api_key)
        else raise Error, "Use rho t3 status|check|projects|project ID|create PATH|token|login codex|login claude"
        end
        out.puts(JSON.pretty_generate(result))
        result
      end

      # `bearer` says whether one is saved, never what it is.
      def status
        { "server" => @settings.server, "url" => @settings.url, "project_id" => @settings.project_id,
          "bearer" => @settings.bearer,
          "configured" => @settings.configured?, "issues" => @settings.issues,
          "installed" => @settings.local? ? @native.installed : nil,
          "native_configuration" => @settings.local? ? @native.root : nil }.compact
      end

      def check
        agents = providers
        selected = projects.any? { |project| project.fetch("id") == @settings.project_id }
        status.merge("service" => { "authenticated" => true, "orchestration_protocol" => 2 },
          "project_available" => selected, "providers" => agents)
      end

      # The coding agents the service reports now. A missing URL or bearer is
      # named before any connection is attempted.
      def providers
        @settings.require_connection
        Catalog.read(@bridge).report
      end

      def projects
        @bridge.projects.map { |project| project_row(project) }
      rescue KeyError, NoMethodError, TypeError
        raise Error, "T3 returned an incomplete project directory", cause: nil
      end

      # A choice the directory cannot honor is the caller's to correct, so it
      # is a configuration refusal rather than a T3 failure.
      def select_project(id)
        project = projects.find { |row| row.fetch("id") == id }
        raise ConfigurationError, "Choose a project id returned by rho t3 projects" unless project

        save_project(project)
      end

      def create_project(path)
        path = path.to_s.strip
        raise ConfigurationError, "Provide an absolute project path in T3's execution environment" unless path.start_with?("/")

        existing = project_at(path)
        return save_project(existing) if existing

        begin
          created = project_row(@bridge.create_project(path: path, title: File.basename(path)))
        rescue Uncertain
          created = project_at(path)
          raise Uncertain, "T3 project creation was not confirmed; inspect rho t3 projects before creating again", cause: nil unless created
        end
        save_project(created)
      end

      # The bearer's one owner is the saved configuration: a local service's
      # is issued natively here, a host service's is the one given — pasted
      # at a hidden prompt or piped on stdin by the CLI, posted by the page.
      # The answer names the outcome, never the bearer.
      def save_token(given = nil)
        token = given.nil? ? (@settings.local? ? issue_token : read_token) : given.to_s.strip
        raise ConfigurationError, "A T3 bearer is required" if token.empty?
        raise ConfigurationError, "The T3 bearer must be a single token without spaces" unless token.match?(BEARER_PATTERN)

        @persist.call(bearer: "saved", operations: [{ "op" => "set", "path" => ["token"], "value" => token }])
      end

      def issue_token
        require_local
        @native.prepare
        token, _error, status = Open3.capture3(@native.environment, "t3", "auth", "session", "issue",
          "--base-dir", @native.server_root, "--label", "rho", "--token-only", unsetenv_others: true)
        token = token.strip
        unless status.success? && token.match?(BEARER_PATTERN)
          raise Error, "Native T3 bearer issuance failed; inspect the native installation"
        end
        token
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

        def project_row(value)
          row = value.to_h
          { "id" => row.fetch("id").to_s, "title" => row.fetch("title").to_s,
            "workspaceRoot" => row.fetch("workspaceRoot").to_s }
        end

        def save_project(project)
          @persist.call(project: project, operations: [{ "op" => "set", "path" => ["project_id"], "value" => project.fetch("id") }])
        end

        # A host service's bearer is issued where that service runs and typed
        # here. A terminal hides what is typed; a pipe hands over one line.
        def read_token
          if @input.tty?
            @prompt.print("T3 bearer (input hidden): ")
            @prompt.flush
            line = @input.noecho(&:gets)
            @prompt.puts
          else
            line = @input.gets
          end
          raise ConfigurationError, "A T3 bearer is required" if line.nil?

          line.strip
        end

        def project_at(path)
          matches = projects.select { |project| project.fetch("workspaceRoot") == path }
          raise ConfigurationError, "Several T3 projects use this path; choose one with rho t3 project ID" if matches.length > 1

          matches.first
        end

        def require_local
          raise Error, "Run native login and bearer issuance on the host that owns T3 in host mode" unless @settings.local?
        end
    end
  end
end
