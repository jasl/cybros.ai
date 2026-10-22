require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"
require "support/mcp_fixture/declarations"
require "support/mcp_fixture/host"

module E2E
  module McpFixture
    # The local stdio/HTTP fixture lifecycle and its public control/read doors.
    # Each journey owns one home, one connection ceremony and its fixture process.
    module Journey
      MODEL = E2E::CatalogOverlay::MCP_MODEL
      AWAIT_SECONDS = 120
      LOOP_POLL = 1
      # The ladder's bound (three stages of three seconds) plus a margin.
      GROUP_DEAD_SECONDS = 15
      SERVER = "fx".freeze
      TIMEOUT_MS = 5000
      # The http row: the same fixture under puma, every tool taken (`"*"`),
      # the http default park, one credential-shaped header over plain http
      # to a LOOPBACK host — the one place the bearer rule admits it.
      REMOTE = "remote".freeze
      REMOTE_TIMEOUT_MS = 60_000
      REMOTE_HEADER = "X-Fixture-Token".freeze
      REMOTE_HEADER_VALUE = "fixture-header-value-0123".freeze
      RHO_ROOT = E2E::RhoDaemon::RHO_ROOT
      FIXTURE = E2E::McpFixture::Host::FIXTURE
      INCUBATION = "direct installation edits are disabled; use managed extensions or develop a separate rho successor".freeze
      WORST_CASE = { "kind" => "write", "destructive" => true, "effect_scope" => "open", "idempotency" => "none",
                     "reconciliation" => "none" }.freeze
      NO_TOOLS_SENTENCE = 'mcp server "fx" names no tools — name the ones you want under "tools", or ["*"] to take ' \
                          "every one; `rho mcp probe fx` prints what it would declare and the bytes".freeze

      def setup
        @base_url = E2E.base_url
        @world = E2E::ActorProvisioning.world(@base_url)
        @steward = @world.rho_steward
        @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
        @page = @actor.page
        @home = Dir.mktmpdir("rho-mcp-e2e")
        @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
        @remote_port = E2E::McpFixture::Host.free_port
        @remote_log_path = File.join(@home, "remote.log")
        write_settings(tools: E2E::McpFixture::ALLOWLIST)
        @actor.visit("/")
        assert @page.has_text?("Overview")
      end

      def teardown
        unless passed?
          warn_log(@daemon&.log_path, "rho daemon stdout")
          warn_log(@daemon&.rho_log_path, "rho structured log")
          warn_log(@remote_log_path, "http fixture")
          %i[runner jobs].each do |host|
            warn_log(E2E.hosts.log_path(host), "nexus #{host}")
          rescue StandardError
            nil
          end
        end
      rescue StandardError => error
        warn "Could not capture the mcp_tools E2E logs: #{error.class}: #{error.message}"
      ensure
        if (result = @daemon&.dispose_connection)
          output, status = result
          assert_predicate status, :success?, output
        end
        stop_http_fixture
        FileUtils.remove_entry(@home) if @home && File.directory?(@home)
      end

      private

        # ---- the settings ----

        def write_settings(tools:)
          row = {
            "transport" => "stdio",
            "command" => Gem.ruby,
            "args" => [Gem.bin_path("bundler", "bundle"), "exec", "ruby", FIXTURE],
            "cwd" => RHO_ROOT,
            "env" => { "BUNDLE_GEMFILE" => File.join(RHO_ROOT, "Gemfile"), "BUNDLE_FROZEN" => "true" },
            "timeout_ms" => TIMEOUT_MS,
          }
          row["tools"] = tools unless tools.nil?
          remote = {
            "transport" => "http", "url" => remote_url, "tools" => ["*"],
            "headers" => { REMOTE_HEADER => REMOTE_HEADER_VALUE },
          }
          File.write(File.join(@home, "settings.json"),
            JSON.pretty_generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.mcp" => { "enabled" => true, "configuration" => { "servers" => { SERVER => row, REMOTE => remote } } } })), perm: 0o600)
        end

        def remote_url = "http://127.0.0.1:#{@remote_port}/mcp"

        def announced_names = fx_names.sort

        def all_names = E2E::McpFixture::TOOLS.map { |tool| tool.fetch("name") }

        # The registry's order is settings order, then each server's listing
        # order: the stdio row's allowlisted five, the http row's every one.
        def fx_names
          all_names.select { |name| E2E::McpFixture::ALLOWLIST.include?(name) }.map { |name| "mcp__#{SERVER}__#{name}" }
        end

        def remote_names = all_names.map { |name| "mcp__#{REMOTE}__#{name}" }

        def expected_bytes(server, names)
          # The CLI measures lowered MCP function entries. Executor source
          # metadata and the later connection-specific callable are separate.
          E2E::McpFixture.announced(server, names).sum do |declaration|
            JSON.generate(CybrosAgent::Api::ToolLowering.function_entry(declaration)).bytesize
          end
        end

        # ---- the http fixture ----

        # The same fixture under puma (`E2E::McpFixture::Host`), booted BEFORE
        # the daemon that lists it and ready once the port answers.
        def start_http_fixture
          @remote_pid = E2E::McpFixture::Host.spawn(entry: "http", port: @remote_port, log: @remote_log_path)
          E2E::McpFixture::Host.await_ready!(@remote_port, log: @remote_log_path)
        rescue E2E::McpFixture::Host::NotListening => error
          flunk "the http fixture never listened: #{error.message}"
        end

        def stop_http_fixture
          E2E::McpFixture::Host.stop(@remote_pid) if @remote_pid
          @remote_pid = nil
        end

        def number(value) = value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

        def connected_pgid(listed)
          pgid = listed[/^server:\s+fx\s+stdio.*connected \(pid \d+, pgid (\d+)\)/, 1]
          refute_nil pgid, "rho mcp shows no connected fx:\n#{listed}"
          Integer(pgid)
        end

        # ---- the CLI ----

        def rho(*args)
          output, status = @daemon.cli(*args)
          assert_predicate status, :success?, "rho #{args.first} failed:\n#{output}"
          output
        end

        # `rho do`: the conversation, its turn, and the loop backing it.
        def open_turn(prompt, project, *flags)
          output = rho("do", prompt, "--model", MODEL, "--dir", project, *flags)
          ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
          refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
          ids
        end

        # THE DIRECTIVE, as the mock parses it: `name:<url-encoded json>`. The
        # arguments come braced (`{ "text" => … }`) or bare (`"text" => …` —
        # keywords, once `server:` exists, hence the splat).
        def directive(raw_name, arguments = nil, server: SERVER, **fields)
          "#{mcp_callable(raw_name, server: server)}:#{CGI.escape(JSON.generate(arguments || fields))}"
        end

        # The Runner's declared callable fixes its source; kernel skill loads retain their own lookup.
        def skill_call(name, callable: "skill") = "#{callable}:#{CGI.escape(JSON.generate("name" => name))}"

        # Settings expose the same source-specific names that execution uses.
        # The fixture knows remote names and schema bytes, never the name hash.
        def mcp_callable(raw_name, server: SERVER)
          tool = mcp_connection(server).fetch("tools").find { |entry| entry.fetch("name") == raw_name }
          refute_nil tool, "#{server} did not expose #{raw_name} in its public MCP directory"
          tool.fetch("callable_name")
        end

        def mcp_connection(server)
          @mcp_directory ||= @daemon.control(:get, "/presets/tools", expected_status: 200).fetch("mcp_connections")
          connection = @mcp_directory.find { |entry| entry.fetch("ref") == mcp_ref(server) }
          refute_nil connection, "the public MCP directory did not expose #{server}: #{@mcp_directory.inspect}"
          assert connection.fetch("available"), server
          connection
        end

        def mcp_ref(server)
          { "source" => "executor", "executor_public_id" => server == SERVER ? rho_runner_id : rho_agent_id,
            "server_key" => server }
        end

        def mcp_function_entries(server, names)
          E2E::McpFixture.announced(server, names).map do |declaration|
            raw_name = declaration.fetch("name").delete_prefix("mcp__#{server}__")
            entry = CybrosAgent::Api::ToolLowering.function_entry(declaration)
            entry.merge("function" => entry.fetch("function").merge("name" => mcp_callable(raw_name, server: server), "strict" => false))
          end
        end

        # ---- the world ----

        def connect!
          start_http_fixture
          agent_announcements = agent_announcement_count
          @daemon.start
          E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
          @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
          E2E.enable_dev_lane!
          E2E.hosts.start
          project = File.join(@home, "project")
          FileUtils.mkdir_p(project)
          @daemon.control(:post, "/environment", body: { root: project })
          await_rho_ready
          await_agent_announced(after: agent_announcements)
          @member = @daemon.member_client
          @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
          @loops = @client.workspace(@workspace_public_id).runs
          project
        end

        # The same home, booted again: the credentials stand, no new grant. A
        # stale announcement would answer the readiness wait for a daemon that
        # is gone, so it is cleared before the boot.
        def restart!
          @mcp_directory = nil
          FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
          agent_announcements = agent_announcement_count
          @daemon.start
          await_workspace_state("adopted")
          await_rho_ready
          await_agent_announced(after: agent_announcements)
        end

        def await_rho_ready
          @daemon.await("rho never announced its tools") do
            runner = @daemon.control(:get, "/runner")["runner"]
            runner if runner && runner["announced"] == runner.fetch("tools").length
          end
        end

        # THE AGENT ADDRESS is ready once THIS boot's `executor.announced …
        # address=agent` line is in the log (the log is appended across the
        # restarts, so the count before the boot is the mark).
        AGENT_ANNOUNCED = /event=executor\.announced tools=\d+ role=agent\b/

        def agent_announcement_count = @daemon.log_text.scan(AGENT_ANNOUNCED).length

        def await_agent_announced(after:)
          @daemon.await("the agent address never announced its tools") { agent_announcement_count > after ? true : nil }
        end

        def rho_runner_id
          @rho_runner_id ||= @daemon.status.dig("identity", "runner_executor_public_id") ||
            flunk("a full-mode rho registers a runner row: #{@daemon.status.inspect}")
        end

        def rho_agent_id
          @rho_agent_id ||= @daemon.status.dig("identity", "executor_public_id") ||
            flunk("a full-mode rho registers an agent row: #{@daemon.status.inspect}")
        end

        def await_workspace_state(state)
          @daemon.await("the daemon never reported workspace #{state}") do
            document = @daemon.status
            workspace = document["workspace"]
            flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

            workspace&.fetch("state") == state ? document : nil
          end
        end

        def await_rho_log(pattern, message)
          @daemon.await(message) { @daemon.log_text.match(pattern) }
        end

        # ---- the reads ----

        def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop}"

        def loop_row(loop)
          document = agent_api(loop_path(loop))
          document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
        end

        def task_detail(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").fetch("task")

        def task_output(loop, task_key) = task_detail(loop, task_key)["output"].to_s

        def agent_api(path)
          uri = URI.join(@base_url, path)
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{@steward.member_token}"
          response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
          JSON.parse(response.body.force_encoding(Encoding::UTF_8))
        end

        def await_run_status(loop, status)
          await("the loop #{loop} never reached #{status}") do
            row = loop_row(loop)
            flunk "the loop failed: #{row["failure_reason"].inspect} #{summarize(row)}" if row["status"] == "failed" && status != "failed"
            row if row["status"] == status
          end
        end

        def await_park(loop)
          await("the call never parked") do
            row = loop_row(loop)
            row.fetch("tasks").find { |task| task["kind"] == "tool_task" && task["status"] == "needs_approval" }
          end
        end

        def await(message, every: LOOP_POLL)
          latest = nil
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
          loop do
            latest = yield
            return latest if latest
            flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep every
          end
        end

        def summarize(row)
          row.fetch("tasks").map do |task|
            "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}#{task["tool_name"] ? "/#{task["tool_name"]}" : ""}" \
              "#{task["error"] ? "/#{task["error"]["key"]}" : ""})"
          end.join(" ")
        end

        def process_group_alive?(pgid)
          Process.kill(0, -pgid)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          # macOS answers EPERM for a group of nothing but zombies: not gone
          # until its leader is reaped, which is the runner's `kill_and_reap`.
          true
        end

        def await_process_group_gone(pgid, within:)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
          until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            return true unless process_group_alive?(pgid)

            sleep 0.2
          end
          !process_group_alive?(pgid)
        end

        LOG_TAIL_LINES = 80

        def warn_log(path, label)
          return unless path && File.file?(path)

          tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
          warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
        end
    end
  end
end
