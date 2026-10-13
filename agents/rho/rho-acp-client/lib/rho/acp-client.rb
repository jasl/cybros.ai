require "rho"
require "rho/runner"
require "rho/acp"
require "json"
require "time"
require_relative "acp-client/version"

module Rho
  # THE ACP CLIENT, AS AN EXTENSION (the client lives on the runner). Another ACP agent an operator names in
  # `settings.json#plugins.rho.acp-client.configuration.agents` is delegated to by the model through ONE
  # runner tool, `delegate_agent` — tool-less until an enabled row exists
  # (naming a row is the consent, rho-mcp's rule one level down). One
  # child process per (conversation, agent), in its own process group,
  # living as long as the conversation (the daemon's `:host_ended`) or
  # the daemon; one call = one `session/prompt`; `session` in the result
  # continues the same child session. The kernel sees an ordinary
  # ToolTask with bash's worst-case profile, judged, addressed and
  # settled by its own stage; inside the call the child's permission
  # requests are answered by rho's OWN floor (`Guard.refusal`) and the
  # row's policy — never parked, no proxy approval. Nothing here changes
  # Nexus: one settings key, the registry's seams, the verbs, `GET /acp`.
  #
  # ITS OWN TOP-LEVEL NAME: `Rho::AcpClient`, never `Rho::Acp::Client`,
  # so the client gem nests nothing under the agent gem's module and the
  # loader's feature `rho/acp-client` maps to it by its own rule
  # (`camelize`: `acp-client` → `AcpClient`). The wire is rho-acp's
  # (`Rho::Acp::Wire`, `Connection`, `Methods`), spoken from the client
  # end; the secrets trio and the child-env scrub are the runner's.
  module AcpClient
    NAME = "rho.acp-client".freeze

    class Error < Rho::Error; end
    # The client is shutting down: a call after `close!`.
    class Closed < Error; end
    # A child that could not be started, or died before it answered: the
    # call's `is_error`, the probe's `down:` line.
    class Unavailable < Error; end
    # A call refused before its turn — the version, a login this runner
    # cannot perform, a session that is gone, a workdir that moved: data
    # the model reads.
    class Refused < Error; end
  end
end

require_relative "acp-client/settings"
require_relative "acp-client/capture"
require_relative "acp-client/policy"
require_relative "acp-client/children"
require_relative "acp-client/call"
require_relative "acp-client/tool"
require_relative "acp-client/commands"

module Rho
  module AcpClient
    class << self
      # THE TWO SEAMS A TEST USES: the settings table (else the host's
      # `Api#configuration`) and the environment the rows' `${NAME}`
      # expand from (else the daemon's own).
      attr_writer :settings_table, :settings_env
      attr_reader :rows, :home, :log, :clock

      def settings_table = @settings_table

      def settings_env = @settings_env || ENV

      def enabled_rows = Array(@rows).reject(&:fault?).select(&:enabled?)

      def row(key) = enabled_rows.find { |candidate| candidate.key == key }

      # THE ENVIRONMENT IS REPLACED, NOT MERGED: the runner's
      # scrub (Bundler's trail, credential-shaped names and rho's own
      # dropped) plus the row's `env` — the hash a third party's process
      # gets whole, under `unsetenv_others: true` at the spawn site.
      def child_env(row, current = ENV.to_h)
        Rho::Runner::ChildEnv.scrubbed(current).merge(row.env)
      end

      # THE DOOR (the loader's contract): the rows parsed at load, the tool
      # bound where the host serves the runner address and a row is
      # enabled, the two routes, the one verb, the hooks. Nothing is
      # spawned here: a child is born at the first delegation.
      def register(api)
        # This integration keeps process-wide sessions; it cannot prepare an
        # independent replacement while calls still use the active instance.
        api.restart_only
        @log = api.log
        @home = api.host&.home
        @clock = api.host&.clock || -> { Time.now }
        rows = Settings.parse(settings_table || api.configuration.fetch("agents", {}), env: settings_env)
        rows.select(&:fault?).each { |fault| @log&.warn("acp.agent_config_invalid", agent: fault.key, sentence: fault.sentence) }
        api.describe_status do
          issues = rows.select(&:fault?).map { |row| "ACP agent #{row.key} needs configuration; inspect rho acp-agents" }
          issues << "No ACP agents are enabled" unless rows.any? { |row| !row.fault? && row.enabled? }
          { ready: issues.empty?, issues: issues }
        end
        klass = Tool.build(rows)
        if klass && api.serves?(:runner)
          api.on(:startup) { check_prerequisites(rows) }
          api.register_tool(klass)
        elsif klass.nil?
          @log&.info("acp.no_agent_enabled", rows: rows.length)
        end
        api.register_route("GET", "/acp") { |_request, _ctx| [200, report] }
        api.register_route("POST", "/acp/kill") { |request, _ctx| kill_route(request) }
        api.register_command("acp-agents", usage: Commands::USAGE, description: Commands::DESCRIPTION) do |cli, args, options|
          Commands.run(cli, args, options)
        end
        api.on(:host_ended) { |host_public_id, *| release(host_public_id.to_s) }
        api.on(:shutdown) { close! }
        @rows = rows
        Children.configure(rows, log: @log)
        nil
      end

      # Child sessions choose their working directory at call time. Check only
      # commands whose location is already determined by the launch environment;
      # project-relative commands and PATH entries remain that session's check.
      def check_prerequisites(rows)
        rows.reject(&:fault?).select(&:enabled?).each do |row|
          command = row.command
          paths = if command.start_with?("/")
            [command]
          elsif command.include?("/")
            next
          else
            directories = child_env(row)["PATH"]&.split(File::PATH_SEPARATOR, -1)
            next if directories.nil? || directories.empty? || directories.any? { |directory| !directory.start_with?("/") }

            directories.map { |directory| File.join(directory, command) }
          end
          unless paths.any? { |path| File.file?(path) && File.executable?(path) }
            raise Rho::Runner::Extensions::PrerequisiteError,
              "ACP agent #{row.key} cannot find an executable command. Install its runtime or correct its command and PATH in " \
              "the ACP agents plugin settings, then enable the plugin again."
          end
        end
        nil
      end

      # THE CALL the tool class makes: the session (a child spawned and
      # handshaken when the pair has none), then one turn on it. A
      # refusal before the turn is data; a child that died is data.
      def call(args, env:)
        raise Closed, "the acp client is shutting down" if Children.closed?

        env.raise_if_cancelled!
        key = args["agent"].to_s
        row = row(key)
        return Rho::Runner::Result.error("no enabled acp agent named #{key.inspect}") if row.nil?

        workdir = args["workdir"].to_s
        cwd = env.resolve(workdir.empty? ? "." : workdir)
        return Rho::Runner::Result.error("Working directory does not exist: #{cwd}") unless File.directory?(cwd)

        context = Rho::Runner::ExecutionContext.current
        conversation = context&.conversation_public_id || context&.run_public_id || "standalone"
        session = Children.acquire(row, conversation: conversation, cwd: cwd, workdir_given: !workdir.empty?,
          session: (args["session"] unless args["session"].to_s.empty?), env: env, artifacts_dir: env.ensure_artifacts_dir!,
          log: @log, clock: @clock || -> { Time.now })
        Call.new(session: session, prompt: args["prompt"].to_s, env: env, home: @home, log: @log,
          clock: @clock || -> { Time.now }).run
      rescue Refused, Unavailable => error
        Rho::Runner::Result.error(error.message)
      end

      # `:host_ended`: the conversation's children let go.
      def release(conversation) = Children.release(conversation, log: @log)

      def close! = Children.close!(log: @log)

      def sweep! = Children.sweep!(log: @log)

      def kill(session_id) = Children.kill(session_id, log: @log)

      # For tests: forget everything — the seams too.
      def reset!
        Children.reset!
        @settings_table = nil
        @settings_env = nil
        @rows = nil
        @log = nil
        @home = nil
        @clock = nil
        nil
      end

      # The document `GET /acp` answers and `rho acp-agents` reads.
      def report
        { "agents" => Array(@rows).map { |row| agent_document(row) }, "sessions" => Children.sessions }
      end

      private

        def agent_document(row)
          if row.fault?
            return { "key" => row.key, "launch" => nil, "description" => nil, "permissions" => nil, "timeout_ms" => nil,
                     "enabled" => true, "state" => "down", "detail" => "config: #{row.sentence}", "env" => [], "children" => 0 }
          end

          redact = Rho::Runner::Redact.new(row.secrets)
          { "key" => row.key, "launch" => redact.call(row.launch), "description" => row.description,
            "permissions" => row.permissions, "timeout_ms" => row.timeout_ms, "enabled" => row.enabled?,
            "state" => row.enabled? ? "enabled" : "disabled", "detail" => nil, "env" => row.env.keys,
            "children" => Children.children_of(row.key) }
        end

        def kill_route(request)
          session = Rho::ControlServer.json_body(request)["session"].to_s
          return Rho::Daemon::Refusal.malformed("session is required") if session.empty?

          document = Children.session_document(session)
          if document.nil? || !kill(session)
            return Rho::Daemon::Refusal.new(status: 404, code: "acp_session_not_found",
              message: "no session #{session} on this daemon")
          end

          [200, { "killed" => true, "session" => session, "agent" => document["agent"], "pid" => document["pid"] }]
        end
    end
  end
end
