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

# `web_fetch` ON RHO: a read of the open world as an extension gem in the runner's shape — one tool,
# `web_fetch {url}`, that GETs a public http(s) URL through httpx with its SSRF filter and same-site
# redirects under one deadline, renders HTML to markdown, answers the head under the runner's own
# truncation caps with bash's spill footer and pages the rest through `read`; announced `read_only`
# on the OPEN world, parked under `ask` by the mode's own word, refused under `rules` until a rule
# allows it, refused for private hosts unless one setting lifts loopback and RFC 1918. The kernel
# changes nothing: the closed vocabulary already carries `read_only` + `open`, and the rule grammar
# already walks `url`. Driven through the shipped binary: `rho runner`, `rho do`, `rho status`, `rho
# approve`, `rho web fetch`, and a restart of the same home.
#
# THE STEPS, in order on one daemon: BOOT + LIST (the extension loads;
# discovery carries the declaration byte for byte on the runner row); THE
# PAGE (the status line, the markdown, nothing of the script or style, no
# zero-width byte; the log names the host, never the URL); THE BOUND, THE
# SPILL, THE PAGING (bash's footer byte for byte, the spill linked, `read
# {offset}` on it); REDIRECTS (a same-site chain rendered byte-equal to
# the page, the 302's body never kept; cross-site REPORTED; the loop
# bound; a 3xx with no Location as data); TEXT, JSON, BYTES, 404, TOO BIG;
# THE REFUSALS THE MODEL READS (six sentences, one fan); THE PARK (`ask`
# parks, `rho approve` releases, the spill's `read` never parks; `rules`
# refuses as data); THE PRIVATE DEFAULT and THE CONFIG FAULT (the same
# home booted again through the harness); THE CLI (`--raw` byte-equal to
# the spill; a refusal is the sentence, exit 1).
#
# ONE CEREMONY PER FILE, ONE GRANT: the full-mode daemon on its own home,
# whose settings name `rho/web-tools` with `"web": {"allow_private_network":
# true}` — the fixture is loopback. The fixture's two puma listeners run
# IN this process, booted before the daemon and halted by the journey.
# No paid lane: whether a MODEL reaches for `web_fetch` is `live_web_fetch`'s.
class WebFetchTest < Minitest::Test
  MODEL = E2E::CatalogOverlay::WEB_FETCH_MODEL
  AWAIT_SECONDS = 120
  LOOP_POLL = 1
  RHO_ROOT = E2E::RhoDaemon::RHO_ROOT
  Fetch = Rho::WebTools::Tools::Fetch
  Truncation = Rho::Runner::Truncation
  PROFILE = { "kind" => "read_only", "destructive" => false, "world" => "open", "idempotency" => "intrinsic",
              "reconciliation" => "none" }.freeze
  # The two settings the journey writes: the fixture's lift, and rho's
  # Config admitting a table the EXTENSION refuses.
  LIFT = { "allow_private_network" => true }.freeze
  BAD_TABLE = { "allow_private_network" => "yes" }.freeze
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
    assert @page.has_text?("Dashboard")
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
    begin
      @daemon&.stop
    rescue StandardError => error
      warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
    end
    @fixture&.stop
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_web_fetch_is_announced_reads_pages_spills_reports_redirects_parks_and_refuses
    project = connect!
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)

    boot_and_list
    page_body = the_page(project)
    spill = the_bound_the_spill_and_the_paging(project)
    redirects(project, page_body)
    text_json_bytes_404_and_too_big(project)
    the_refusals_the_model_reads(project)
    the_park_and_the_rules(project, spill)
    the_private_default_and_the_config_fault(project)
    the_cli(spill)
  end

  private

    # ---- 1. BOOT + LIST ----

    def boot_and_list
      runner = rho("runner")
      assert_match(/^extension: rho\.web_tools \(web_fetch\)$/, runner, "the extension loaded with its one tool:\n#{runner}")
      refute_match(/^FAILED:/, runner, "an extension failed to load:\n#{runner}")

      # DISCOVERY: the runner row's served tools carry the declaration
      # VERBATIM — the class's constants, byte for byte — beside Coding's.
      served = @client.executors.show(rho_runner_id).served_tools
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
      truncation = detail.fetch("structured_content").fetch("truncation")
      assert_equal true, truncation.fetch("truncated"), truncation.inspect
      assert_equal shown, truncation.fetch("output_lines")

      # THE PAGING: `read {path, offset: N+1}` answers the next lines of the
      # page. A second loop: the mock is stateless and scripts its calls at
      # `rho do`, and the spill's name is minted by the tool.
      _c, _t, paged = open_turn("!mock tool_call=read:#{CGI.escape(JSON.generate("path" => spill, "offset" => shown + 1))} -- done", project)
      done = await_loop_status(paged, "completed")
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

    # ---- 4. REDIRECTS ----

    def redirects(project, page_body)
      # A same-site chain: the final page rendered byte-equal to step 2's,
      # the 302's own HTML body never reaching the accumulator.
      _c, _t, loop = open_turn(prompt(url("/same")), project)
      row, output, detail = completed_call(loop)
      refute row.dig("result", "is_error"), row.inspect
      status_line, body = split_status_line(output)
      assert_match(/\A#{Regexp.escape(url("/page.html"))} — 200 text\/html; .* \(1 redirect\); title: Fixture Page\z/, status_line, output)
      assert_equal page_body, body, "the rendering is byte-equal to the page's: the 302's body never landed"
      refute_includes output, "Redirecting"
      assert_equal url("/same"), detail.fetch("structured_content").fetch("url")
      assert_equal url("/page.html"), detail.fetch("structured_content").fetch("final_url")
      await_rho_log(/event=web\.fetch host=127\.0\.0\.1 status=200 content_type=text\/html bytes=\d+ rendered_bytes=\d+ redirects=1 ms=\d+/,
        "the followed hop was never logged")

      # Cross-site: REPORTED, never followed.
      _c, _t, loop = open_turn(prompt(url("/away")), project)
      row, output, detail = completed_call(loop)
      assert_equal true, row.dig("result", "is_error"), "a cross-site redirect is an error result: #{row.inspect}"
      assert_equal "redirect: #{url("/away")} → #{other_url("/page.html")} (302); #{REDIRECT_SENTENCE}", output
      assert_equal other_url("/page.html"), detail.fetch("structured_content").fetch("final_url")
      assert_equal 302, detail.fetch("structured_content").fetch("status")
      refute_includes @fixture.requests, other_url("/page.html"), "the other site was asked: #{@fixture.requests.inspect}"

      # The bound: three hops without an answer.
      _c, _t, loop = open_turn(prompt(url("/loop")), project)
      row, output, _detail = completed_call(loop)
      assert_equal true, row.dig("result", "is_error"), row.inspect
      assert_equal "#{url("/loop")} redirected 3 times without answering; web_fetch follows at most 3 redirects", output

      # A 3xx that names no Location is DATA the model reads.
      _c, _t, loop = open_turn(prompt(url("/gone")), project)
      row, output, detail = completed_call(loop)
      assert_equal true, row.dig("result", "is_error"), row.inspect
      assert_equal "#{url("/gone")} answered 300 Multiple Choices\n\n#{E2E::WebFixture::GONE}", output
      assert_equal 300, detail.fetch("structured_content").fetch("status")
    end

    # ---- 5. TEXT, JSON, BYTES, 404, TOO BIG ----

    def text_json_bytes_404_and_too_big(project)
      _c, _t, loop = open_turn(prompt(url("/notes.txt")), project)
      row, output, _detail = completed_call(loop)
      refute row.dig("result", "is_error"), row.inspect
      # Verbatim under the runner's own line convention (`truncate_head`
      # keeps whole lines joined by newlines): the file's trailing newline
      # opens no line, so it is not one the model reads.
      assert_equal "#{url("/notes.txt")} — 200 text/plain; #{size(E2E::WebFixture::NOTES)} fetched\n\n#{E2E::WebFixture::NOTES.chomp}", output,
        "text is the body verbatim under the status line"

      _c, _t, loop = open_turn(prompt(url("/data.json")), project)
      row, output, _detail = completed_call(loop)
      refute row.dig("result", "is_error"), row.inspect
      assert_equal "#{url("/data.json")} — 200 application/json; #{size(E2E::WebFixture::DATA)} fetched\n\n#{E2E::WebFixture::DATA}", output

      # BYTES: saved always, named by the path's extension, linked; `read`
      # on the file answers read's own "image attached".
      png = E2E::RedSquarePng.bytes
      _c, _t, loop = open_turn(prompt(url("/pixel.png")), project)
      row, output, detail = completed_call(loop)
      refute row.dig("result", "is_error"), row.inspect
      match = output.match(/\A#{Regexp.escape(url("/pixel.png"))} — 200 image\/png; #{Regexp.escape(size(png))} saved to (\S+)\z/)
      refute_nil match, "the bytes line:\n#{output}"
      path = match[1]
      assert_match(/\Aweb-\h{16}\.png\z/, File.basename(path))
      assert_equal captures_dir(project), File.dirname(path), "saved under the work dir, keyed by the root — never in the project"
      assert_equal png, File.binread(path), "the saved bytes are the fixture's"
      links = Array(detail["content"]).select { |block| block["type"] == "resource_link" }
      assert_equal 1, links.length, detail["content"].inspect
      assert_equal File.basename(path), links.first.fetch("name")
      assert_equal "image/png", detail.fetch("structured_content").fetch("content_type")
      _c, _t, read_loop = open_turn("!mock tool_call=read:#{CGI.escape(JSON.generate("path" => path))} -- done", project)
      done = await_loop_status(read_loop, "completed")
      read = done.fetch("tasks").find { |task| task["tool_name"] == "read" }
      assert_equal "completed", read.fetch("status"), summarize(done)
      assert_equal "#{File.basename(path)}: image attached", task_output(read_loop, read.fetch("key")).strip

      # 404: data, with the body's first bytes.
      _c, _t, loop = open_turn(prompt(url("/missing")), project)
      row, output, detail = completed_call(loop)
      assert_equal true, row.dig("result", "is_error"), row.inspect
      assert_match(/\A#{Regexp.escape(url("/missing"))} answered 404 Not Found\n\nno such page\n/, output)
      assert_equal 404, detail.fetch("structured_content").fetch("status")

      # TOO BIG: the Content-Length refuses it at the first chunk, nothing
      # counted — the sentence and the zero are the witnesses that no body
      # was read (the wall-clock claim is rho-web-tools's own `client_test`).
      _c, _t, loop = open_turn(prompt(url("/big")), project)
      row, output, detail = completed_call(loop)
      assert_equal true, row.dig("result", "is_error"), row.inspect
      assert_equal "127.0.0.1 answered Content-Length 6.0MB; web_fetch reads at most 5.0MB", output
      assert_equal 0, detail.fetch("structured_content").fetch("bytes")
      await_rho_log(/event=web\.refused host=127\.0\.0\.1 reason=too_large/, "the refusal was never logged")
    end

    # ---- 6. THE REFUSALS THE MODEL READS ----

    # Six calls in ONE round (a parallel fan): each answered with its
    # sentence as an error result, the loop completing; the three judged
    # before a socket leave the fixture's request count where it was.
    def the_refusals_the_model_reads(project)
      requests_before = @fixture.requests.length
      calls = {
        "scheme" => { "url" => "ftp://x" },
        "credentials" => { "url" => "http://u:p@127.0.0.1:#{site_port}/" },
        "canonical" => { "url" => "http://LOCALHOST:#{site_port}/page.html" },
        "encoding" => { "url" => url("/Köln") },
        "metadata" => { "url" => "http://169.254.169.254/latest/meta-data/" },
        "schema" => {},
      }
      fan = calls.values.map { |arguments| "web_fetch:#{CGI.escape(JSON.generate(arguments))}" }.join("&")
      _c, _t, loop = open_turn("!mock tool_call=#{fan} -- done", project)
      done = await_loop_status(loop, "completed")
      rows = done.fetch("tasks").select { |task| task["tool_name"] == "web_fetch" }
      assert_equal calls.length, rows.length, summarize(done)
      by_input = rows.to_h do |row|
        detail = task_detail(loop, row.fetch("key"))
        assert_equal "completed", row.fetch("status"), row.inspect
        assert_equal true, row.dig("result", "is_error"), "a refusal is an error result: #{row.inspect}"
        [detail.fetch("tool_input"), detail.fetch("output").to_s]
      end
      sentence = ->(name) { by_input.fetch(calls.fetch(name)) }

      assert_equal "url must be http:// or https://", sentence.call("scheme")
      credentials = sentence.call("credentials")
      assert_equal "url carries credentials before the host; web_fetch sends none — remove them and call again", credentials
      refute_includes credentials, "u:"
      refute_includes credentials, "p@"
      assert_equal "url host \"LOCALHOST\" is not canonical; write it in lowercase ASCII without a trailing dot, " \
                   "an IPv4 address as four dotted decimals", sentence.call("canonical")
      assert_equal "url is not a valid URL; percent-encode non-ASCII characters in the path and query, " \
                   "and write the host in lowercase ASCII", sentence.call("encoding")
      # The lift is loopback and RFC 1918 ONLY: the metadata endpoint stays
      # refused under it, by name, before any socket.
      assert_equal "169.254.169.254 resolves to a private or reserved address; web_fetch reaches public hosts only " \
                   "(settings.json \"web\": {\"allow_private_network\": true} lifts loopback and RFC 1918)",
        sentence.call("metadata")
      assert_match(/missing required properties: url/, sentence.call("schema"), "the schema's own refusal")
      assert_equal requests_before, @fixture.requests.length, "a refusal opened a socket: #{@fixture.requests.drop(requests_before).inspect}"
    end

    # ---- 7. THE PARK, AND THE RULES ----

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
      done = await_loop_status(loop, "completed")
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
      done = await_loop_status(loop, "completed")
      refused = done.fetch("tasks").find { |task| task["tool_name"] == "web_fetch" }
      refute_nil refused, summarize(done)
      assert_equal "failed", refused.fetch("status"), refused.inspect
      assert_equal({ "key" => "approval_denied", "detail" => RULES_SENTENCE }, refused.fetch("error"))
      refute refused.key?("approval"), "a rule's deny stamps no fact: #{refused.inspect}"
    end

    # ---- 8. THE PRIVATE DEFAULT, THE CONFIG FAULT ----

    def the_private_default_and_the_config_fault(project)
      # Without `web`: loopback is refused by default, as the sentence says.
      @daemon.stop
      write_settings(web: nil)
      restart!
      _c, _t, loop = open_turn(prompt(url("/page.html")), project)
      row, output, _detail = completed_call(loop)
      assert_equal true, row.dig("result", "is_error"), row.inspect
      assert_equal "127.0.0.1 resolves to a private or reserved address; web_fetch reaches public hosts only " \
                   "(settings.json \"web\": {\"allow_private_network\": true} lifts loopback and RFC 1918)", output
      await_rho_log(/event=web\.refused host=127\.0\.0\.1 reason=private_address/, "the private refusal was never logged")

      # A table rho's Config admits (an object) and the EXTENSION refuses:
      # its failure, recorded; the daemon serves Coding without it.
      @daemon.stop
      write_settings(web: BAD_TABLE)
      restart!
      runner = rho("runner")
      assert_match(/^FAILED:\s+gem:rho\/web-tools — settings\.json "web": allow_private_network must be true or false, not "yes"$/, runner,
        "the bad table is the extension's failure:\n#{runner}")
      refute_match(/^extension: rho\.web_tools/, runner, "a failed extension registers nothing:\n#{runner}")
      refute_includes @client.executors.show(rho_runner_id).served_tools.map(&:name), "web_fetch",
        "the runner row announces no web_fetch"
      note = File.join(project, "note.txt")
      File.write(note, "still served\n")
      _c, _t, loop = open_turn("!mock tool_call=read tool_args=#{CGI.escape(JSON.generate("path" => note))} -- done", project)
      done = await_loop_status(loop, "completed")
      read = done.fetch("tasks").find { |task| task["tool_name"] == "read" }
      assert_equal "completed", read.fetch("status"), summarize(done)
      assert_includes task_output(loop, read.fetch("key")), "still served"

      # Restored for the CLI: the verb reads the settings file itself.
      write_settings(web: LIFT)
    end

    # ---- 9. THE CLI ----

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
      settings = { "extensions" => ["rho/web-tools", "rho/dev"] }
      settings["web"] = web unless web.nil?
      File.write(File.join(@home, "settings.json"), JSON.pretty_generate(settings))
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
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # THE DIRECTIVE, as the mock parses it: `web_fetch:<url-encoded json>`.
    def directive(fetch_url) = "web_fetch:#{CGI.escape(JSON.generate("url" => fetch_url))}"

    def prompt(fetch_url) = "!mock tool_call=#{directive(fetch_url)} -- done"

    # The one `web_fetch` row of a completed loop: the row, its output text
    # and the single-task read.
    def completed_call(loop)
      done = await_loop_status(loop, "completed")
      row = done.fetch("tasks").find { |task| task["tool_name"] == "web_fetch" }
      refute_nil row, summarize(done)
      assert_equal "completed", row.fetch("status"), "the call did not complete: #{summarize(done)} #{row.inspect}"
      detail = task_detail(loop, row.fetch("key"))
      [row, detail.fetch("output").to_s, detail]
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

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("agent_loop") { flunk "the loop read was refused: #{document.inspect}" }
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

    def await_loop_status(loop, status)
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
