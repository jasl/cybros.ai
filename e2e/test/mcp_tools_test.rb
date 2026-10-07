require "test_helper"
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

# MCP ON RHO, THE STDIO AND HTTP HALVES AND THE DOCUMENTS: an MCP server is a tool source behind an
# executor — rho runs the client, curates what the operator named, announces each tool VERBATIM
# under `mcp__<server>__<tool>` with the worst-case effect profile, and the kernel, which never
# speaks MCP, addresses, judges and settles the call exactly as it does `bash`. A stdio server
# (`fx`) rides the RUNNER address; a streamable-HTTP server (`remote`, the same fixture under puma
# on a loopback port, `tools: "*"`) rides the AGENT address — announced by the daemon's agent slot
# beside the delegate summarizer, addressed by the kernel as `agent_application`. Each server's
# prompts and resources are DOCUMENTS on its row: `fx-*` announced by the runner address and loaded
# by its `skill`, `remote-*` by the agent address and the plane's `skill` rho-mcp registers there;
# the kernel routes each `skill` row to its announcer. Driven through the shipped binary: `rho
# runner`, `rho mcp`, `rho mcp probe`, `rho do`, `rho status`, `rho approve`, and a restart of the
# same home.
#
# THE STEPS, in order on one daemon: BOOT + LIST (the extension loads, the
# fixture's five stdio tools and seven http tools announced with their
# bytes, discovery carries the declarations byte for byte on each row);
# CALLS (a parallel fan on one stdio connection and the http row, the
# wire's entries the fixture's own bytes, the structured content, the
# derived incubation deny binding under bypass on both rows; the four
# `skill` loads routed to their announcers with the prompt text, the
# readme and the mimeType-less notes as content); THE
# ALLOWLIST (an un-allowlisted name is `unknown_tool` at the kernel); THE
# PARK (the worst-case profile rests under `ask`, `rho approve` releases);
# THE CLAMP (a hang is clamped, the group killed, the next call restarts
# with the notice); DEATH UNDER A CALL (`failed` naming the exit, the loop
# absorbs, the next call restarts); THE GROUP DIES WITH THE DAEMON; THE
# CONFIG FAULT IS ONE ROW'S (no `tools`: listed down, nothing spawned,
# the http row still served, the probe prints the declaration, a re-list
# is a boot).
#
# ONE CEREMONY PER FILE, ONE GRANT: the full-mode daemon on its own home,
# whose settings name `rho/mcp` and the fixture server twice; step 8
# restarts the SAME home (no second pairing). The http fixture is booted
# BEFORE the daemon and closed by the journey. No paid lane: whether a
# MODEL reaches for a prefixed tool is `live_mcp`'s.
class McpToolsTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
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
    assert @page.has_text?("Dashboard")
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

  def test_a_stdio_mcp_server_is_curated_announced_called_clamped_restarted_and_configured_per_row
    project = connect!
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @loops = @client.workspace(@workspace_public_id).runs

    pgid = boot_and_list
    calls_a_parallel_fan_the_bytes_and_the_derived_deny(project)
    the_allowlist_on_the_wire(project)
    the_worst_case_profile_parks_under_ask(project)
    pgid = the_clamp_then_the_teardown(project, pgid)
    pgid = death_under_a_call_then_the_restart(project, pgid)
    the_group_dies_with_the_daemon(pgid)
    the_config_fault_is_one_rows_and_a_relist_is_a_boot(project)
  end

  private

    # ---- 1. BOOT + LIST ----

    def boot_and_list
      runner = rho("runner")
      assert_match(/^extension: rho\.mcp \(#{(fx_names + remote_names + ["skill"]).map { |n| Regexp.escape(n) }.join(", ")}\)$/, runner,
        "the extension loaded with the five stdio and seven http names, in settings then listing order, and the plane's " \
        "skill it serves on the agent address for the http row's documents:\n#{runner}")
      refute_match(/^FAILED:/, runner, "an extension failed to load:\n#{runner}")

      announced = await_rho_log(/event=mcp\.announced server=fx tools=5 bytes=(\d+)/, "the boot never logged mcp.announced")
      bytes = announced[1].to_i
      assert_equal expected_bytes(SERVER, E2E::McpFixture::ALLOWLIST), bytes, "the logged bytes are the lowered entries' sum"
      assert_operator bytes, :<, 4971, "five fixture tools cost less than rho's whole toolset"
      assert_match(/level=info event=mcp\.announced/, @daemon.log_text, "under the reference: INFO, not WARN")
      assert_match(/event=mcp\.connected server=fx protocol_version=\S+ server_name=fx-server server_version=1\.0\.0 tools=7 prompts=2 resources=3/,
        @daemon.log_text)
      assert_match(/event=mcp\.announced server=fx tools=5 bytes=\d+ reference_bytes=4971 documents=3/, @daemon.log_text,
        "three of the five listed prompts and resources are documents")
      remote_announced = await_rho_log(/event=mcp\.announced server=remote tools=7 bytes=(\d+)/, "the http row never announced")
      remote_bytes = remote_announced[1].to_i
      assert_equal expected_bytes(REMOTE, all_names), remote_bytes, "the http row's bytes are its seven lowered entries"
      assert_match(/event=mcp\.connected server=remote protocol_version=\S+ server_name=fx-server server_version=1\.0\.0 tools=7/,
        @daemon.log_text, "the http fixture identified itself over the gem's HTTP client")

      listed = rho("mcp")
      pgid = listed[/^server:\s+fx\s+stdio\s+.*\s+serves runner\s+connected \(pid (\d+), pgid (\d+)\)\s+\S+\s+fx-server 1\.0\.0$/, 2]
      refute_nil pgid, "rho mcp did not print a connected fx with its pid and pgid:\n#{listed}"
      assert_match(/^  tools:   5 announced of 7 listed — #{number(bytes)} bytes$/, listed, listed)
      announced_names.each do |name|
        assert_match(/^    #{Regexp.escape(name)}\s+[\d,]+ bytes  write\/destructive\/open \(worst case\)$/, listed, listed)
      end
      assert_match(/^\s+incubation deny not derivable for "file\.path"$/, listed, "the lookup's dotted property is listed:\n#{listed}")
      assert_match(/^    skipped: write \(not in tools\), env \(not in tools\)$/, listed, listed)
      assert_match(/^  env:     BUNDLE_GEMFILE=•••  BUNDLE_FROZEN=•••$/, listed, "names only, every value masked:\n#{listed}")
      # THE DOCUMENTS: each server's three announced of five listed, the skips by the name they
      # would have carried, with their reasons.
      [SERVER, REMOTE].each do |server|
        assert_includes listed, "  documents: 3 announced of 5 listed\n" \
                                "    #{server}-summarize (prompt)  #{server}-readme (resource, text/markdown)  #{server}-notes (resource)\n" \
                                "    skipped: #{server}-greet (prompt: required argument \"who\"), #{server}-blob (resource: application/octet-stream)\n",
          "the #{server} row's documents lines:\n#{listed}"
      end
      # THE HTTP ROW: a session, not a process — no pid, no pgid; the
      # launch line is the url; the header by NAME, its value masked.
      assert_match(/^server:\s+remote\s+http\s+#{Regexp.escape(remote_url)}\s+serves agent\s+connected\s+\S+\s+fx-server 1\.0\.0$/,
        listed, "rho mcp did not print a connected remote on the agent address:\n#{listed}")
      assert_match(/^  tools:   7 announced of 7 listed — #{number(remote_bytes)} bytes$/, listed, listed)
      remote_names.each do |name|
        assert_match(/^    #{Regexp.escape(name)}\s+[\d,]+ bytes  write\/destructive\/open \(worst case\)$/, listed, listed)
      end
      assert_match(/^  headers: #{REMOTE_HEADER}: •••$/, listed, "every header value masked:\n#{listed}")
      refute_includes listed, REMOTE_HEADER_VALUE
      assert_match(/^total:     12 tools announced, #{number(bytes + remote_bytes)} bytes; 6 documents$/, listed, listed)

      # DISCOVERY: the runner row's served tools carry the declarations
      # VERBATIM — the fixture's description and schema, byte for byte —
      # under the worst-case profile and the row's park, beside Coding's;
      # nothing of the http server rides it.
      runner_row = @client.executors.show(rho_runner_id)
      served = runner_row.served_tools
      mcp = served.select { |tool| tool.name.start_with?("mcp__") }
      assert_equal announced_names, mcp.map(&:name).sort
      assert_verbatim(mcp, E2E::McpFixture.announced(SERVER), TIMEOUT_MS)
      assert_includes served.map(&:name), "read", "Coding's tools stand beside the MCP ones"
      refute(served.any? { |tool| tool.name.start_with?("mcp__remote__") }, "an http server's tool never rides the runner row")
      # THE RUNNER ROW'S DOCUMENTS: the stdio server's three, with the server's own descriptions,
      # beside the project's (none); nothing of the http server's. The kernel serves the list
      # ordered by name.
      assert_equal E2E::McpFixture.documents(SERVER).sort_by { |document| document.fetch("name") },
        runner_row.served_documents.map { |document| { "name" => document.name, "description" => document.description } },
        "the runner row announces the stdio server's documents verbatim"
      assert_match(/event=executor\.announced tools=\d+ address=runner documents=3\b/, @daemon.log_text)

      # THE AGENT ROW is not a machine kind: the kernel's discovery never offers an agent
      # application's row to a member (`executors#index` lists `MACHINE_KINDS`), so its announcement
      # is read where it is written — the daemon's own line for the kernel's accepted PUT: the seven
      # http tools beside the delegate summarizer, `todo_write`, `read_schedules`,
      # `manage_schedule`, `list_extensions`, `manage_extension`, `code` and the plane's
      # `skill` for the row's three documents.
      # The bytes the kernel holds for them are
      # pinned on the wire in step 2, and the addressing to the agent there; the documents by the
      # loads of step 2.
      assert_match(/event=executor\.announced tools=#{remote_names.length + 8} address=agent documents=3\b/, @daemon.log_text,
        "the agent address announced the http tools beside the delegate, todo tracker, schedules, extensions, code and skill, with the http server's documents:\n" \
        "#{@daemon.log_text.scan(/event=executor\.\S+.*/).join("\n")}")
      refute_match(/event=executor\.announcement_failed/, @daemon.log_text)
      Integer(pgid)
    end

    def assert_verbatim(served, declarations, timeout_ms)
      declarations.each do |declaration|
        tool = served.find { |candidate| candidate.name == declaration.fetch("name") }
        refute_nil tool, declaration.fetch("name")
        assert_equal WORST_CASE, tool.effect_profile, tool.name
        assert_equal timeout_ms, tool.timeout_ms, tool.name
        assert_equal declaration.fetch("description"), tool.description, "#{tool.name}: the description is the server's"
        assert_equal declaration.fetch("inputSchema"), tool.input_schema, "#{tool.name}: the schema is the server's"
      end
    end

    # ---- 2. CALLS, A PARALLEL FAN, THE BYTES, THE DERIVED DENY ----

    def calls_a_parallel_fan_the_bytes_and_the_derived_deny(project)
      fan = [
        "tool_search:#{CGI.escape(JSON.generate("query" => "mcp__", "limit" => 20))}",
        "#{directive("echo", "text" => "hello from the world")}&#{directive("lookup", "key" => "k1")}&" \
          "#{directive("echo", { "text" => "over http" }, server: REMOTE)}",
        directive("paths", "paths" => ["/tmp/a", "/tmp/b"]),
      ].join(",")
      _conversation, _turn, loop = open_turn("!mock tool_call=#{fan} -- done", project)
      completed = await_run_status(loop, "completed")

      # Discovery preserves all MCP schemas with provider-bound strict: false.
      # The schemas stay deferred from the initial and subsequent requests.
      sealed = @loops.run(loop).tasks_context("r1").request
      wired = sealed.request_options.fetch("tools").select { |tool| tool.dig("function", "name").start_with?("mcp__") }
      assert_empty wired
      searched = completed.fetch("tasks").select { |task| task["tool_name"] == "tool_search" }
      assert_equal 1, searched.length
      assert_equal "completed", searched.fetch(0).fetch("status")
      found = JSON.parse(task_output(loop, searched.fetch(0).fetch("key")))
      assert_equal false, found.fetch("truncated")
      discovered = found.fetch("tools").map { |entry| entry.fetch("definition") }
      expected = CybrosAgent::Api::ToolLowering.function_entries(
        E2E::McpFixture.announced(SERVER) + E2E::McpFixture.announced(REMOTE, all_names)
      ).map { |entry| entry.merge("function" => entry.fetch("function").merge("strict" => false)) }
      by_name = ->(entry) { entry.dig("function", "name") }
      assert_equal expected.sort_by(&by_name), discovered.sort_by(&by_name),
        "discovered MCP definitions preserve both rows with explicit non-strict semantics"
      completed.fetch("tasks").select { |task| task["kind"] == "model_task" }.each do |task|
        assert_equal sealed.request_options.fetch("tools"), @loops.run(loop).tasks_context(task.fetch("key")).request.request_options.fetch("tools"),
          "discovery never promotes MCP schemas into later requests"
      end

      rows = completed.fetch("tasks").select { |task| task["kind"] == "tool_task" && task["tool_name"] != "tool_search" }
      assert_equal %w[mcp__fx__echo mcp__fx__lookup mcp__fx__paths mcp__remote__echo],
        rows.map { |row| row.fetch("tool_name") }.sort, summarize(completed)
      rows.each { |row| assert_equal "completed", row.fetch("status"), row.inspect }
      rows.select { |row| row.fetch("tool_name").start_with?("mcp__fx__") }.each do |row|
        assert_equal "runner", row.dig("addressed_to", "role"), "addressed to rho's runner: #{row.inspect}"
        assert_equal rho_runner_id, row.dig("addressed_to", "executor_public_id")
      end
      echo, lookup, remote_echo = %w[mcp__fx__echo mcp__fx__lookup mcp__remote__echo].map do |name|
        rows.find { |row| row.fetch("tool_name") == name }
      end
      # THE HTTP ROW is addressed to the daemon's AGENT address and answered
      # by its agent slot: the same fixture's text, over the gem's HTTP client.
      assert_equal "agent_application", remote_echo.dig("addressed_to", "role"), "addressed to the agent: #{remote_echo.inspect}"
      assert_equal rho_agent_id, remote_echo.dig("addressed_to", "executor_public_id")
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}over http", task_output(loop, remote_echo.fetch("key")).strip,
        "the http echo's content is the fixture's text"
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}hello from the world", task_output(loop, echo.fetch("key")).strip,
        "echo's content is the fixture's text"
      detail = task_detail(loop, lookup.fetch("key"))
      assert_equal E2E::McpFixture::LOOKUP_RECORD.merge("key" => "k1"), detail.fetch("structured_content"),
        "lookup's structured content is the fixture's object: #{detail.inspect}"
      assert_equal "2 paths", task_output(loop, rows.find { |row| row.fetch("tool_name") == "mcp__fx__paths" }.fetch("key")).strip
      assert_equal 4, @daemon.claimed_keys.count { |key| rows.map { |row| row.fetch("key") }.include?(key) },
        "rho's two slots claimed all four: #{@daemon.claims.inspect}"

      # THE DERIVED DENY binds under bypass on BOTH rows: a text naming this home's root is refused
      # by the kernel with the deny-rule explanation, the loop completes, nothing reaches either
      # slot.
      runner_skill = @loops.run(loop).task("r1").tool_definitions.find do |entry|
        entry.dig("route", "runner_executor_public_id") == rho_runner_id && entry.dig("route", "tool_name") == "skill"
      end
      refute_nil runner_skill, "the Runner skill has its own declaration beside the kernel skill"
      the_documents_load_through_their_announcers(project, runner_skill.fetch("function").fetch("name"))

      root = File.realpath(@home)
      [SERVER, REMOTE].each do |server|
        # Task keys repeat per loop (`r2t0` in every loop), so "nothing
        # reached a slot" is the claim COUNT standing still across the loop.
        claims_before = @daemon.claims.length
        _c, _t, denied = open_turn(
          "!mock tool_call=#{directive("echo", { "text" => "please edit #{root}/settings.json" }, server: server)} -- done", project
        )
        done = await_run_status(denied, "completed")
        refused = done.fetch("tasks").find { |task| task["tool_name"] == "mcp__#{server}__echo" }
        refute_nil refused, summarize(done)
        assert_equal "failed", refused.fetch("status"), refused.inspect
        assert_equal({ "key" => "approval_denied", "detail" => INCUBATION }, refused.fetch("error"), server)
        assert_equal claims_before, @daemon.claims.length, "a denied call never reaches a slot (#{server}): #{@daemon.claims.inspect}"
      end
    end

    # THE DOCUMENTS LOAD: source-qualified Runner calls and a kernel skill call preserve their
    # declared authority — `fx-*` on its Runner, `remote-summarize` on the agent address — and
    # answered with the prompt's text, the readme's body and the mimeType-less notes' text, byte for
    # byte; a name nobody announced (`fx-greet`, skipped for its required argument) runs in-process
    # and is `skill_unknown`.
    def the_documents_load_through_their_announcers(project, runner_callable)
      names = %w[fx-summarize fx-readme fx-notes remote-summarize fx-greet]
      # Task keys repeat per loop, so the claims of THIS loop are the ones
      # past the count before it opened.
      claims_before = @daemon.claims.length
      calls = names.map do |name|
        callable = %w[fx-summarize fx-readme fx-notes].include?(name) ? runner_callable : "skill"
        skill_call(name, callable: callable)
      end
      _c, _t, loop = open_turn("!mock tool_call=#{calls.join(",")} -- done", project)
      done = await_run_status(loop, "completed")
      rows = done.fetch("tasks").select { |task| task["tool_name"] == "skill" }
      assert_equal 5, rows.length, summarize(done)
      details = rows.to_h { |row| [task_detail(loop, row.fetch("key")).dig("tool_input", "name"), row] }
      assert_equal names.sort, details.keys.sort, summarize(done)
      details.each_value { |row| assert_equal "completed", row.fetch("status"), row.inspect }

      %w[fx-summarize fx-readme fx-notes].each do |name|
        row = details.fetch(name)
        assert_equal "runner", row.dig("addressed_to", "role"), "#{name} is routed to its announcer: #{row.inspect}"
        assert_equal rho_runner_id, row.dig("addressed_to", "executor_public_id")
      end
      remote = details.fetch("remote-summarize")
      assert_equal "agent_application", remote.dig("addressed_to", "role"), "the http server's document loads through the agent address: #{remote.inspect}"
      assert_equal rho_agent_id, remote.dig("addressed_to", "executor_public_id")
      assert_nil details.fetch("fx-greet")["addressed_to"], "a name nobody announced runs in-process"

      assert_equal E2E::McpFixture::SUMMARIZE_TEXT, task_output(loop, details.fetch("fx-summarize").fetch("key")),
        "the prompt's messages' text is the body"
      assert_equal E2E::McpFixture::README_TEXT, task_output(loop, details.fetch("fx-readme").fetch("key")),
        "the resource's text is the body, verbatim"
      assert_equal E2E::McpFixture::NOTES_TEXT, task_output(loop, details.fetch("fx-notes").fetch("key")),
        "a listing with no mimeType reads by its contents' text"
      assert_equal E2E::McpFixture::SUMMARIZE_TEXT, task_output(loop, remote.fetch("key")), "the same prompt over the http row"
      assert_equal "skill_unknown: fx-greet", task_output(loop, details.fetch("fx-greet").fetch("key")).strip
      claims = @daemon.claims.drop(claims_before)
      assert_equal 4, claims.length, "the two slots claimed the four announced loads and nothing else: #{claims.inspect}"
      assert_equal details.values_at("fx-summarize", "fx-readme", "fx-notes", "remote-summarize").map { |row| row.fetch("key") }.sort,
        claims.map { |line| line.fetch("task") }.sort, "the claims are the four announced loads' rows"
      assert_equal %w[agent runner runner runner], claims.map { |line| line["address"] }.sort,
        "three loads on the runner slot, one on the agent slot: #{claims.inspect}"
      claims.each { |line| assert_equal "skill", line.fetch("tool"), "the same `skill` row, addressed to its announcer" }
    end

    # ---- 3. THE ALLOWLIST ON THE WIRE ----

    def the_allowlist_on_the_wire(project)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("write", "text" => "x")} -- done", project)
      done = await_run_status(loop, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "mcp__fx__write" }
      refute_nil row, summarize(done)
      assert_equal "failed", row.fetch("status"), row.inspect
      assert_equal "unknown_tool", row.dig("error", "key"), "a name outside the declaration is a task-row failure: #{row.inspect}"
      assert_match(/^    skipped: write \(not in tools\)/, rho("mcp"))
    end

    # ---- 4. THE WORST-CASE PROFILE → THE PARK ----

    def the_worst_case_profile_parks_under_ask(project)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("echo", "text" => "held")} -- done", project, "--approval", "ask")
      held = await_park(loop)
      key = held.fetch("key")
      assert_equal "mcp__fx__echo", held.fetch("tool_name")
      inbox = @daemon.control(:get, "/asks").fetch("asks")
      assert_equal 1, inbox.length, inbox.inspect
      assert_equal %w[approval mcp__fx__echo], inbox.first.values_at("kind", "tool_name"), inbox.inspect
      # The kernel stores the five keys PLUS the announced park on every
      # row alike (`TaskExecutor::Announcement#effect_profile_for`), so
      # the approver reads the worst case and the 5 s park beside it.
      assert_equal WORST_CASE.merge("timeout_ms" => TIMEOUT_MS), inbox.first.fetch("effect_profile"),
        "the approver reads the worst case"
      status = rho("status")
      assert_match(/^approvals:\s+1 pending$/, status, status)

      approved = rho("approve", loop, key)
      assert_match(/^approved:\s+#{Regexp.escape(key)}$/, approved, approved)
      done = await_run_status(loop, "completed")
      task = done.fetch("tasks").find { |t| t.fetch("key") == key }
      assert_equal "completed", task.fetch("status"), summarize(done)
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}held", task_output(loop, key).strip
    end

    # ---- 5. THE CLAMP, THEN THE TEARDOWN ----

    def the_clamp_then_the_teardown(project, pgid)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("hang", {})} -- done", project)
      done = await_run_status(loop, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "mcp__fx__hang" }
      assert_equal "completed", row.fetch("status"), "the clamp's answer is data: #{summarize(done)}"
      output = task_output(loop, row.fetch("key"))
      assert_equal "The tool timed out: its granted execution deadline passed before it returned a result. " \
                   "Cancellation was requested; external effects may be incomplete. " \
                   "Check its effect before calling it again.", output,
        "the shared timeout result preserves uncertainty about external effects"
      assert await_process_group_gone(pgid, within: GROUP_DEAD_SECONDS), "the fx group #{pgid} survived the poison rule"
      listed = await("rho mcp never showed the kill") do
        text = rho("mcp")
        text if text.match?(/down: killed after a timed-out call \(mcp__fx__hang\)/)
      end
      assert_match(/^server:\s+fx\s+stdio.*down: killed after a timed-out call \(mcp__fx__hang\) at \d\d:\d\d:\d\d$/, listed, listed)
      await_rho_log(/event=mcp\.server_killed server=fx tool=mcp__fx__hang/, "the kill was never logged")

      _c, _t, again = open_turn("!mock tool_call=#{directive("echo", "text" => "after the clamp")} -- done", project)
      done = await_run_status(again, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "mcp__fx__echo" }
      assert_equal "completed", row.fetch("status"), summarize(done)
      output = task_output(again, row.fetch("key"))
      assert_equal "note: mcp server fx had been stopped after a timed-out call (mcp__fx__hang) and was restarted for this " \
                   "call; any state it held is gone\n#{E2E::McpFixture::ECHO_TEXT_PREFIX}after the clamp", output.strip
      new_pgid = connected_pgid(rho("mcp"))
      refute_equal pgid, new_pgid, "a restarted server is a new group"
      new_pgid
    end

    # ---- 6. DEATH UNDER A CALL, THEN THE RESTART ----

    def death_under_a_call_then_the_restart(project, pgid)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("exit", {})} -- done", project)
      done = await_run_status(loop, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "mcp__fx__exit" }
      assert_equal "failed", row.fetch("status"), "transport dead, server gone → failed: #{summarize(done)}"
      assert_match(/mcp server fx exited \(status 3\) during mcp__fx__exit/, row.dig("error", "detail").to_s, row.inspect)
      assert_match(/the next call restarts it/, task_output(loop, row.fetch("key")))
      assert await_process_group_gone(pgid, within: GROUP_DEAD_SECONDS), "the dead server's group #{pgid} was not reaped"
      listed = await("rho mcp never showed the exit") do
        text = rho("mcp")
        text if text.match?(/down: exited \(status 3\)/)
      end
      assert_match(/^server:\s+fx\s+stdio.*down: exited \(status 3\) at \d\d:\d\d:\d\d$/, listed, listed)

      _c, _t, again = open_turn("!mock tool_call=#{directive("echo", "text" => "after the exit")} -- done", project)
      done = await_run_status(again, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "mcp__fx__echo" }
      assert_equal "completed", row.fetch("status"), summarize(done)
      output = task_output(again, row.fetch("key"))
      assert_match(/\Anote: mcp server fx had exited \(status 3 at \d\d:\d\d:\d\d; its stderr ended: fixture: leaving with status 3\) and was restarted for this call; any state it held is gone\n#{Regexp.escape(E2E::McpFixture::ECHO_TEXT_PREFIX)}after the exit\z/,
        output.strip)
      new_pgid = connected_pgid(rho("mcp"))
      refute_equal pgid, new_pgid
      new_pgid
    end

    # ---- 7. THE GROUP DIES WITH THE DAEMON ----

    def the_group_dies_with_the_daemon(pgid)
      assert process_group_alive?(pgid), "the fx group should be live before the stop"
      @daemon.stop
      assert await_process_group_gone(pgid, within: GROUP_DEAD_SECONDS), "the fx group #{pgid} outlived the daemon"
    end

    # ---- 8. THE CONFIG FAULT IS ONE ROW'S; A RE-LIST IS A BOOT ----

    def the_config_fault_is_one_rows_and_a_relist_is_a_boot(project)
      announced_before = @daemon.log_text.scan(/event=mcp\.announced/).length
      write_settings(tools: nil)
      restart!
      runner = rho("runner")
      assert_match(/^extension: rho\.mcp \(#{(remote_names + ["skill"]).map { |n| Regexp.escape(n) }.join(", ")}\)$/, runner,
        "the extension loads with the http row's tools alone, and the agent's skill for its documents:\n#{runner}")
      refute_match(/^FAILED:/, runner, "a row's fault is never the extension's:\n#{runner}")
      listed = rho("mcp")
      assert_match(/^server:\s+fx\s+stdio\s+.*down: config: #{Regexp.escape(NO_TOOLS_SENTENCE)}$/, listed, listed)
      refute_match(/pid \d+/, listed, "nothing was spawned to count:\n#{listed}")
      assert_match(/^server:\s+remote\s+http\s+.*serves agent\s+connected\s/, listed, "one row's fault is one row's:\n#{listed}")
      assert_equal 1, listed.scan(/^  documents: 3 announced of 5 listed$/).length, "the http row's documents alone:\n#{listed}"
      assert_match(/^total:     7 tools announced, [\d,]+ bytes; 3 documents$/, listed, listed)
      assert_empty @client.executors.show(rho_runner_id).served_documents, "the row down announces no document"
      assert_equal announced_before + 1, @daemon.log_text.scan(/event=mcp\.announced/).length,
        "the http row announced again; nothing for the row down"
      assert_match(/event=mcp\.server_config_invalid server=fx/, @daemon.log_text)

      # The daemon still serves Coding.
      note = File.join(project, "note.txt")
      File.write(note, "still served\n")
      _c, _t, loop = open_turn("!mock tool_call=read tool_args=#{CGI.escape(JSON.generate("path" => note))} -- done", project)
      done = await_run_status(loop, "completed")
      read = done.fetch("tasks").find { |task| task["tool_name"] == "read" }
      assert_equal "completed", read.fetch("status"), summarize(done)
      assert_includes task_output(loop, read.fetch("key")), "still served"

      # THE PROBE from the CLI: every listed tool, its bytes and the total,
      # and no group left behind.
      probed = rho("mcp", "probe", SERVER)
      assert_match(/^server:\s+fx\s+down: config: #{Regexp.escape(NO_TOOLS_SENTENCE)}$/, probed, probed)
      probe_pgid = probed[/connected \(pid \d+, pgid (\d+)\)/, 1]
      refute_nil probe_pgid, "the probe never connected:\n#{probed}"
      all = E2E::McpFixture::TOOLS.map { |tool| tool.fetch("name") }
      assert_match(/^  tools:   7 listed — 7 would be announced, #{number(expected_bytes(SERVER, all))} bytes$/, probed, probed)
      all.each do |name|
        declaration = E2E::McpFixture::TOOLS.find { |tool| tool.fetch("name") == name }
        assert_match(/^    mcp__fx__#{name}  [\d,]+ bytes  \(worst case\)$/, probed, probed)
        assert_includes probed, "      description (#{declaration.fetch("description").bytesize} bytes): #{declaration.fetch("description")}\n"
      end
      assert_match(/^      incubation deny not derivable for "file\.path"$/, probed, probed)
      # The probe prints the documents as the daemon would announce them,
      # and the template that never is one.
      assert_includes probed, "  documents: 5 listed — 3 would be announced\n"
      assert_includes probed, "    fx-summarize  (prompt)\n      description (#{E2E::McpFixture::SUMMARIZE_DESCRIPTION.bytesize} bytes): " \
                              "#{E2E::McpFixture::SUMMARIZE_DESCRIPTION}\n"
      assert_includes probed, "    fx-greet  (prompt)  skipped: prompt: required argument \"who\"\n"
      assert_includes probed, "    fx-notes  (resource)\n"
      assert_includes probed, "    fx-blob  (resource, application/octet-stream)  skipped: resource: application/octet-stream\n"
      assert_includes probed, "  resource_templates: 1 listed (never a document)\n    note  fx://notes/{id}\n"
      assert await_process_group_gone(Integer(probe_pgid), within: GROUP_DEAD_SECONDS), "the probe left its group #{probe_pgid} behind"

      # THE ROW RESTORED: a re-list is a boot.
      @daemon.stop
      write_settings(tools: E2E::McpFixture::ALLOWLIST)
      restart!
      runner = rho("runner")
      assert_match(/^extension: rho\.mcp \(#{(fx_names + remote_names + ["skill"]).map { |n| Regexp.escape(n) }.join(", ")}\)$/, runner, runner)
      assert_equal 2, @daemon.log_text.scan(/event=mcp\.announced server=fx tools=5/).length,
        "the boot re-listed and announced again"
      assert_match(/connected \(pid \d+, pgid \d+\)/, rho("mcp"))
      await("the restored row never announced its documents again") do
        listed = @client.executors.show(rho_runner_id).served_documents.map(&:name)
        listed if listed == E2E::McpFixture.documents(SERVER).map { |document| document.fetch("name") }.sort
      end
    end

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
      "mcp__#{server}__#{raw_name}:#{CGI.escape(JSON.generate(arguments || fields))}"
    end

    # The Runner's declared callable fixes its source; kernel skill loads retain their own lookup.
    def skill_call(name, callable: "skill") = "#{callable}:#{CGI.escape(JSON.generate("name" => name))}"

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
      project
    end

    # The same home, booted again: the credentials stand, no new grant. A
    # stale announcement would answer the readiness wait for a daemon that
    # is gone, so it is cleared before the boot.
    def restart!
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
    AGENT_ANNOUNCED = /event=executor\.announced tools=\d+ address=agent\b/

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
