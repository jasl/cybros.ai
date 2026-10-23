require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "rho/runner"
require "support/actor_provisioning"
require "support/ceremony"
require "support/red_square_png"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"
require "support/web_fixture"
# The tool's own declaration, for the byte-for-byte discovery pin: the
# harness loads rho-runner's lib by load path already (test_helper), and
# the class carries nothing but constants until it is called.
require_relative "../../agents/rho/rho-web-tools/lib/rho/web-tools/tools/fetch"

# The installed web-tools extension fetches a real local page, spills the long rendering,
# exposes the uploaded bytes and lets a later Runner read continue them. The model-facing
# call parks under ask and runs after human approval; site grants last until daemon restart.
# The CLI reads the same page and spill. Protocol/status/configuration matrices live in
# rho-web-tools/test; these journeys retain extension discovery and actual execution.
#
# Each journey owns its daemon home and explicitly allows the loopback fixture.
# The two fixture listeners start before the daemon and stop during teardown.
class WebFetchTest < Minitest::Test
  MODEL = E2E::CatalogOverlay::WEB_FETCH_MODEL
  AWAIT_SECONDS = 120
  LOOP_POLL = 1
  Fetch = Rho::WebTools::Tools::Fetch
  Truncation = Rho::Runner::Truncation
  PROFILE = { "kind" => "read_only", "destructive" => false, "effect_scope" => "open", "idempotency" => "intrinsic",
              "reconciliation" => "none" }.freeze
  # Allow the local fixture through the extension's private-network setting.
  LIFT = { "allow_private_network" => true }.freeze
  REDIRECT_SENTENCE = "web_fetch follows redirects on the same site only — call web_fetch with the new url to follow it".freeze
  RULES_SENTENCE = "no approval rule allows web_fetch".freeze
  ZERO_WIDTH_SPACE = "​".freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-web-tools-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    @fixture = E2E::WebFixture.new.start
    write_settings(web: LIFT)
    @actor.visit("/")
    assert @page.has_text?("Overview")
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
    end
  rescue StandardError => error
    warn "Could not capture the web_fetch E2E logs: #{error.class}: #{error.message}"
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    @fixture&.stop
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_web_fetch_is_announced_reads_spills_and_requires_approval
    project = connect!
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)

    boot_and_list
    the_page(project)
    spill = the_bound_the_spill_and_the_paging(project)
    the_park_and_the_rules(project, spill)
    the_cli(spill)
  end

  def test_site_grant_allows_paths_requires_the_literal_site_and_expires_at_restart
    project = connect!
    _c, _t, loop = open_turn(prompt(url("?grant=first")), project, "--approval", "ask")
    held = await_park(loop)
    assert_empty @fixture.requests, "the held call must not reach the site"

    approved = rho("approve", loop, held.fetch("key"), "--always")
    assert_includes approved, "#{@fixture.site}/*"
    rule = { "tool" => "web_fetch", "path" => "url", "match" => "#{@fixture.site}/*", "verdict" => "allow" }
    grants = @daemon.control(:get, "/rules").fetch("grants")
    assert_equal [rule], grants.map { |grant| grant.fetch("rule") }
    assert_includes rho("rules"), "#{@fixture.site}/*"
    first, = completed_call(loop)
    assert_equal "agent", first.dig("approval", "origin"), "the held bare query is approved once"
    assert_equal 1, @fixture.requests.length

    _c, _t, loop = open_turn(prompt(url("/page.html?grant=same")), project, "--approval", "ask")
    same, output, = completed_call(loop)
    assert_equal "rule", same.dig("approval", "origin"), "a later path is approved by the kernel's declared rule"
    refute same.dig("result", "is_error"), same.inspect
    assert_includes output, "# Fixture Heading"
    assert_equal [url("/"), url("/page.html")], @fixture.requests

    [other_url("/page.html"), url("?grant=again"), "http://127.0.0.1.example.com:#{site_port}/page.html"].each do |outside|
      requests_before = @fixture.requests.dup
      _c, _t, loop = open_turn(prompt(outside), project, "--approval", "ask")
      held = await_park(loop)
      assert_equal "web_fetch", held.fetch("tool_name")
      assert_equal requests_before, @fixture.requests, "an unmatched URL must not reach either fixture: #{outside}"
      rho("deny", loop, held.fetch("key"), "outside the site grant")
      await_run_status(loop, "completed")
      assert_equal requests_before, @fixture.requests, "denial must not fetch: #{outside}"
    end

    @daemon.stop
    restart!
    assert_empty @daemon.control(:get, "/rules").fetch("grants")
    requests_before = @fixture.requests.dup
    _c, _t, loop = open_turn(prompt(url("/page.html")), project, "--approval", "ask")
    held = await_park(loop)
    assert_equal requests_before, @fixture.requests, "the old grant must not survive restart"
    rho("deny", loop, held.fetch("key"), "grant expired at restart")
    await_run_status(loop, "completed")
    assert_equal requests_before, @fixture.requests
  end

  private

    # ---- 1. BOOT + LIST ----

    def boot_and_list
      runner = rho("runner")
      assert_match(/^extension: rho\.web_tools \(web_fetch\)$/, runner, "the extension loaded with its one tool:\n#{runner}")
      refute_match(/^FAILED:/, runner, "an extension failed to load:\n#{runner}")

      # DISCOVERY: the runner row's served tools carry the declaration
      # VERBATIM — the class's constants, byte for byte — beside Coding's.
      served = @daemon.member_client.executors.show(rho_runner_id).tools_for(:runner)
      tool = served.find { |candidate| candidate.name == Fetch::NAME }
      refute_nil tool, "web_fetch is not on the runner row: #{served.map(&:name).inspect}"
      assert_equal PROFILE, tool.effect_profile
      assert_equal Fetch::TIMEOUT_MS, tool.timeout_ms
      assert_equal 60_000, tool.timeout_ms
      assert_equal Fetch::DESCRIPTION, tool.description, "the description is the class's, byte for byte"
      assert_equal Fetch::SCHEMA, tool.input_schema, "the schema is the class's, byte for byte"
      assert_includes served.map(&:name), "read", "Coding's tools stand beside it"
    end

    # ---- 2. THE PAGE ----

    def the_page(project)
      _c, _t, loop = open_turn(prompt(url("/page.html")), project)
      row, output, detail = completed_call(loop)
      assert_equal "runner", row.dig("addressed_to", "role"), "addressed to rho's runner: #{row.inspect}"
      assert_equal rho_runner_id, row.dig("addressed_to", "executor_public_id")
      refute row.dig("result", "is_error"), "the page is not an error: #{row.inspect}"

      status_line, body = split_status_line(output)
      assert_match(/\A#{Regexp.escape(url("/page.html"))} — 200 text\/html; [\d.]+K?B fetched, [\d.]+K?B markdown; title: Fixture Page\z/,
        status_line, "the status line opens the result:\n#{output}")
      assert_includes body, "# Fixture Heading"
      assert_includes body, "[link text](#{url("/other")})", "the link, as markdown:\n#{body}"
      assert_includes body, "![a red square](#{url("/pixel.png")})", "the image, as markdown:\n#{body}"
      refute_includes body, "STRIPPED_SCRIPT", "the script's text never reaches the model"
      refute_includes body, "STRIPPED_STYLE", "the style's text never reaches the model"
      refute_includes output, ZERO_WIDTH_SPACE, "the zero-width space is stripped from the rendering"
      assert_equal 200, detail.fetch("structured_content").fetch("status")
      assert_equal url("/page.html"), detail.fetch("structured_content").fetch("final_url")
      links = Array(detail["content"]).select { |block| block["type"] == "resource_link" }
      assert_empty links, "nothing to link on a page under the bound: #{detail["content"].inspect}"

      # THE LOG NAMES THE HOST, NEVER THE URL.
      line = await_rho_log(/event=web\.fetch host=127\.0\.0\.1 status=200 content_type=text\/html bytes=\d+ rendered_bytes=\d+ redirects=0 ms=\d+/,
        "the fetch was never logged")
      refute_nil line
      refute_match(%r{/page\.html}, @daemon.log_text, "a log line carries the URL's path")
      body
    end

    # ---- 3. THE BOUND, THE SPILL, THE PAGING ----

    def the_bound_the_spill_and_the_paging(project)
      _c, _t, loop = open_turn(prompt(url("/long.html")), project)
      row, output, detail = completed_call(loop)
      refute row.dig("result", "is_error"), row.inspect
      footer = output.lines.last.to_s.chomp
      match = footer.match(/\A\[Showing lines 1-(\d+) of (\d+) \(#{Regexp.escape(Truncation.format_size(Truncation::DEFAULT_MAX_BYTES))} limit\)\. Full output: (\S+)\]\z/)
      refute_nil match, "the result does not end with bash's footer:\n#{output.lines.last(3).join}"
      shown = Integer(match[1])
      total = Integer(match[2])
      spill = match[3]
      assert_operator shown, :<, total
      assert_equal captures_dir(project), File.dirname(spill), "the spill lives in the runner's captures directory under the work dir, keyed by the root — never in the project"
      assert_match(/\Aweb-\h{16}\.md\z/, File.basename(spill))
      assert_path_exists spill, "the whole rendering was written"
      # The whole rendering on disk is what the head was cut from: the head
      # (between the status line and the footer) is its first `shown` lines.
      whole = File.read(spill, encoding: Encoding::UTF_8)
      assert_equal total, whole.lines.count, "the footer counts the spill's lines"
      _status_line, head = split_status_line(output)
      head = head.delete_suffix("\n\n#{footer}")
      # `truncate_head` keeps whole lines joined by newlines, no trailing one.
      assert_equal whole.lines.first(shown).join.chomp, head, "the head is the spill's first #{shown} lines"
      assert_includes task_output(loop, "r2"), head, "the model reads the full visible head before it answers"

      # THE SPILL IS LINKED (the one upload site): one `resource_link`
      # block beside the text, named by the file.
      links = Array(detail["content"]).select { |block| block["type"] == "resource_link" }
      assert_equal 1, links.length, "one link to the spill: #{detail["content"].inspect}"
      assert_equal File.basename(spill), links.first.fetch("name")
      assert_match(%r{\Anexus://uploads/[0-9a-f-]+\z}, links.first.fetch("uri"))
      uploaded, status = @daemon.cli_bytes("fetch", links.first.fetch("uri").delete_prefix("nexus://uploads/"))
      assert_predicate status, :success?, "rho fetch could not read the linked spill"
      assert_equal whole.b, uploaded, "the public resource link serves the whole spill byte for byte"
      truncation = detail.fetch("structured_content").fetch("truncation")
      assert_equal true, truncation.fetch("truncated"), truncation.inspect
      assert_equal shown, truncation.fetch("output_lines")

      # THE PAGING: `read {path, offset: N+1}` answers the next lines of the
      # page. A second loop: the mock is stateless and scripts its calls at
      # `rho do`, and the spill's name is minted by the tool.
      _c, _t, paged = open_turn("!mock tool_call=read:#{CGI.escape(JSON.generate("path" => spill, "offset" => shown + 1))} -- done", project)
      done = await_run_status(paged, "completed")
      read = done.fetch("tasks").find { |task| task["tool_name"] == "read" }
      refute_nil read, summarize(done)
      assert_equal "completed", read.fetch("status"), summarize(done)
      paged_output = task_output(paged, read.fetch("key"))
      expected_next = whole.lines[shown].chomp
      assert_includes paged_output, expected_next, "the read continues where the head stopped:\n#{paged_output.lines.first(3).join}"
      refute_includes paged_output, whole.lines.first.chomp, "the read does not restart at line 1"
      assert_includes task_output(paged, "r2"), paged_output, "the model reads the actual page returned by read"
      spill
    end

    # ---- 4. THE PARK, AND THE RULES ----

    def the_park_and_the_rules(project, spill)
      # `ask` parks the open-world read; the spill's `read` behind it, in the
      # same loop, is granted by rho's reads rule and never parks.
      script = "#{directive(url("/long.html"))},read:#{CGI.escape(JSON.generate("path" => spill))}"
      _c, _t, loop = open_turn("!mock tool_call=#{script} -- done", project, "--approval", "ask")
      held = await_park(loop)
      key = held.fetch("key")
      assert_equal "web_fetch", held.fetch("tool_name")
      inbox = @daemon.control(:get, "/asks").fetch("asks")
      assert_equal 1, inbox.length, inbox.inspect
      assert_equal %w[approval web_fetch], inbox.first.values_at("kind", "tool_name"), inbox.inspect
      assert_equal PROFILE.merge("timeout_ms" => Fetch::TIMEOUT_MS), inbox.first.fetch("effect_profile"),
        "the approver reads the announced profile and the park"
      status = rho("status")
      assert_match(/^approvals:\s+1 pending$/, status, status)

      approved = rho("approve", loop, key)
      assert_match(/^approved:\s+#{Regexp.escape(key)}$/, approved, approved)
      done = await_run_status(loop, "completed")
      fetched = done.fetch("tasks").find { |task| task.fetch("key") == key }
      assert_equal "completed", fetched.fetch("status"), summarize(done)
      # `rho approve` decides through the daemon's own credential: the fact
      # reads `origin: agent` with the deciding principal, never `mode`.
      assert_equal "agent", fetched.dig("approval", "origin"), "released by rho approve: #{fetched.inspect}"
      refute_nil fetched.dig("approval", "decided_by"), "the deciding principal is stamped: #{fetched.inspect}"
      read = done.fetch("tasks").find { |task| task["tool_name"] == "read" }
      refute_nil read, summarize(done)
      assert_equal "completed", read.fetch("status"), summarize(done)
      assert_equal "rule", read.dig("approval", "origin"), "the spill's read was granted by rule, never parked: #{read.inspect}"
      assert_includes task_output(loop, read.fetch("key")), File.read(spill, encoding: Encoding::UTF_8).lines.first.chomp
      assert_empty @daemon.control(:get, "/asks").fetch("asks"), "the inbox is empty again"

      # `rules`: refused as DATA unless a rule allows it — the stricter
      # reading, so that a per-host allow row (the operator's, the grant
      # verb's) is never defeated by an ask row.
      _c, _t, loop = open_turn(prompt(url("/page.html")), project, "--approval", "rules")
      done = await_run_status(loop, "completed")
      refused = done.fetch("tasks").find { |task| task["tool_name"] == "web_fetch" }
      refute_nil refused, summarize(done)
      assert_equal "failed", refused.fetch("status"), refused.inspect
      assert_equal({ "key" => "approval_denied", "detail" => RULES_SENTENCE }, refused.fetch("error"))
      refute refused.key?("approval"), "a rule's deny stamps no fact: #{refused.inspect}"
    end

    # ---- 5. THE CLI ----

    def the_cli(spill)
      # `--raw`: the WHOLE rendering to stdout, byte-equal to the spill the
      # tool wrote from the same page; the status line on stderr (not
      # captured by the bytes reader — inherited, so it shows in the run log).
      raw, status = @daemon.cli_bytes("web", "fetch", "--raw", url("/long.html"))
      assert_predicate status, :success?, "rho web fetch --raw failed"
      assert_equal File.binread(spill), raw, "the CLI's rendering is the spill's bytes"
      refute_includes raw, "[Showing lines", "no truncation and no footer at the CLI"

      # The default: what the model would read, whole, invisible bytes
      # escaped. The render already stripped the page's zero-width space
      # (step 2 pinned it), so the escaped text and the raw text agree and
      # neither carries the byte; the status line leads (stderr, merged).
      merged = rho("web", "fetch", url("/page.html"))
      status_line, rendering = merged.split("\n", 2)
      assert_match(/\A#{Regexp.escape(url("/page.html"))} — 200 text\/html; .*; title: Fixture Page\z/, status_line, merged)
      raw_page, status = @daemon.cli_bytes("web", "fetch", "--raw", url("/page.html"))
      assert_predicate status, :success?
      assert_equal raw_page.force_encoding(Encoding::UTF_8), rendering, "a clean render escapes to itself"
      refute_includes rendering, ZERO_WIDTH_SPACE
      refute_includes rendering, "\\u{200B}", "nothing invisible survived the render to be escaped"
      assert_includes rendering, "# Fixture Heading"

      # A refusal is the sentence the model would read, exit 1.
      output, status = @daemon.cli("web", "fetch", url("/away"))
      refute_predicate status, :success?, "a cross-site redirect exits non-zero:\n#{output}"
      assert_equal 1, status.exitstatus
      assert_includes output, "redirect: #{url("/away")} → #{other_url("/page.html")} (302); #{REDIRECT_SENTENCE}"
    end

    # ---- the settings ----

    def write_settings(web:)
      entry = { "enabled" => true }
      entry["configuration"] = web unless web.nil?
      settings = E2E::RhoDaemon.dev_settings(plugins: { "rho.web_tools" => entry })
      File.write(File.join(@home, "settings.json"), JSON.pretty_generate(settings), perm: 0o600)
    end

    # ---- the fixture's addresses ----

    def url(path) = "#{@fixture.site}#{path}"

    def other_url(path) = "#{@fixture.other}#{path}"

    def site_port = URI.parse(@fixture.site).port

    def size(text) = Truncation.format_size(text.bytesize)

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

    # THE DIRECTIVE, as the mock parses it: `web_fetch:<url-encoded json>`.
    def directive(fetch_url) = "web_fetch:#{CGI.escape(JSON.generate("url" => fetch_url))}"

    def prompt(fetch_url) = "!mock tool_call=#{directive(fetch_url)} -- done"

    # The one `web_fetch` row of a completed loop: the row, its text block
    # and the single-task read. The output projection also carries resource links.
    def completed_call(loop)
      done = await_run_status(loop, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "web_fetch" }
      refute_nil row, summarize(done)
      assert_equal "completed", row.fetch("status"), "the call did not complete: #{summarize(done)} #{row.inspect}"
      detail = task_detail(loop, row.fetch("key"))
      text = detail.fetch("content").select { |block| block.fetch("type") == "text" }
      assert_equal 1, text.length, "web_fetch returns one text block beside any resource links"
      [row, text.fetch(0).fetch("text"), detail]
    end

    # The status line, then the rendering after the blank line.
    def split_status_line(output)
      status_line, rest = output.split("\n\n", 2)
      [status_line.to_s, rest.to_s]
    end

    # ---- the world ----

    def connect!
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      @daemon.control(:post, "/environment", body: { root: project })
      await_rho_ready
      project
    end

    # The same home, booted again: the credentials stand, no new grant. A
    # stale announcement would answer the readiness wait for a daemon that
    # is gone, so it is cleared before the boot.
    def restart!
      FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
      @daemon.start
      await_workspace_state("adopted")
      await_rho_ready
    end

    def await_rho_ready
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
    end

    def rho_runner_id
      @rho_runner_id ||= @daemon.status.dig("identity", "runner_executor_public_id") ||
        flunk("a full-mode rho registers a runner row: #{@daemon.status.inspect}")
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

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end

  # Where the runner places a root's captures: under the world's RHO_WORK_DIR (the fixture leaves
  # the default, RHO_HOME/work), keyed by the root's digest — the same placement `Daemon.boot`
  # wires.
  def captures_dir(project)
    Rho::Runner::ToolEnv.artifacts_dir_for(root: project, work_dir: File.join(@daemon.home, "work"))
  end
end
