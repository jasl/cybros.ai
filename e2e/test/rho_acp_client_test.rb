require "test_helper"
require "rho/runner"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/steward_session"

# RHO AS AN ACP CLIENT: another ACP agent an operator names in `settings.json#acp_agents` is
# delegated to by the model through ONE runner tool, `delegate_agent` — the kernel, which never
# speaks ACP, addresses, judges and settles the call exactly as it does `bash`. The agent here is
# the harness's scripted one (`support/acp_fixture/agent.rb`), one row per argv mode; the model is
# the mock, told to CALL the tool by `!mock tool_call=delegate_agent:…`.
#
# THE PINS, in order on one daemon: BOOT + LIST (the extension loads, the
# one tool announced with the longest row's park and the rows' words, the
# roster verb); THE FLOOR TURN (the echo, the trailer, the capture read
# back through `rho fetch`, the child listed with its pid and group); THE
# REUSE (a second call in the same conversation rides the SAME child, a
# `session` continues one child session, a moved `workdir` is refused by
# name); THE RELAY (the fixture's permission mode: `npm test` allowed by
# the policy, `rm -rf /` and a path under `$RHO_HOME` refused by the
# floor, the `reject` row refusing the benign one, an id-only request
# judged by its tracked tool_call, each decision in `rho.log`); PROGRESS
# (the child's ticks reach `rho watch`); CANCEL (`rho stop LOOP KEY` →
# `session/cancel` in the capture, the child alive, its row listed, the
# turn canceled — the call is a spine fan member, so the person's verb is
# the loop's `stop`, never a branch cancel by key); THE
# WALL (`timeout_ms: 2000` on `sleep` → the group killed, nothing of it
# left, the row gone); DEATH (`die` → `is_error` naming the exit and the
# stderr tail, the row gone); THE DOORS (a login the row names, a login
# this runner cannot perform, an elicitation declined and quoted, the
# row's model set); THE VERBS (`probe`, `disable|enable`, `kill`, `logs`);
# THE PARK under `--approval ask` (once, whole); THE CONVERSATION'S END
# (archived through the SDK → `:host_ended` → the child gone); NO ROWS,
# NO TOOL (a restart on an empty table loads clean and lists no tool).
#
# ONE CEREMONY PER FILE, ONE GRANT: a full-mode daemon on its own home,
# whose settings name `rho/acp-client` and `rho/dev` and carry the fixture
# rows; the last step restarts the SAME home. No paid lane: whether a
# MODEL reaches for `delegate_agent` is the live lane's (a later step).
class RhoAcpClientTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  AWAIT_SECONDS = 120
  LOOP_POLL = 1
  # The ladder's bound (three stages of three seconds) plus a margin.
  GROUP_DEAD_SECONDS = 15
  AGENT = File.expand_path("../support/acp_fixture/agent.rb", __dir__)
  WALL_TIMEOUT_MS = 2000
  DEFAULT_TIMEOUT_MS = 600_000
  SECRET = "fixture-secret-value-0123456789".freeze
  INCUBATION = "an agent never edits its own checkout or home; develop a successor as a separate install".freeze
  TRAILER = /session: (acp-[0-9a-f]{12}) · stop: (\w+) · calls: (\d+) \((\d+) refused by the floor\) · capture: (\S+)/

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-acp-client-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: { "FX_TOKEN" => SECRET })
    write_settings(rows: rows)
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
    warn "Could not capture the rho_acp_client E2E logs: #{error.class}: #{error.message}"
  ensure
    begin
      @daemon&.stop
    rescue StandardError => error
      warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
    end
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_delegate_agent_hands_work_to_a_scripted_agent_relays_its_permissions_cancels_and_releases_it
    project = connect!
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @workspace = @client.workspace(@workspace_public_id)
    @loops = @workspace.agent_loops

    boot_and_list
    conversation, session, pid = the_floor_turn_and_the_capture(project)
    the_child_is_reused_and_a_session_continues(project, conversation, session, pid)
    the_floor_the_policy_and_the_id_only_request(project)
    progress_reaches_rho_watch(project)
    cancel_keeps_the_child(project)
    the_wall_kills_the_group(project)
    a_death_is_answered_by_name(project)
    the_doors(project)
    the_verbs(project)
    the_park_under_ask(project)
    the_conversations_end_releases_the_child(conversation, pid)
    no_rows_no_tool(project)
  end

  private

    # ---- 1. BOOT + LIST ----

    def boot_and_list
      runner = rho("runner")
      assert_match(/^extension: rho\.acp-client \(delegate_agent\)$/, runner, "the extension loaded with its one tool:\n#{runner}")
      refute_match(/^FAILED:/, runner, "an extension failed to load:\n#{runner}")

      served = @client.executors.show(rho_runner_id).served_tools
      tool = served.find { |candidate| candidate.name == "delegate_agent" }
      refute_nil tool, "the runner row serves delegate_agent: #{served.map(&:name).inspect}"
      assert_equal DEFAULT_TIMEOUT_MS, tool.timeout_ms, "the announced park is the longest enabled clock"
      assert_equal %w[agent prompt], tool.input_schema.fetch("required")
      assert_equal rows.keys.sort, tool.input_schema.dig("properties", "agent", "enum").sort, "the enum is the enabled keys"
      rows.each_value { |row| assert_includes tool.description, row.fetch("description"), "the rows' words are the model's text" }
      assert_includes served.map(&:name), "read", "Coding's tools stand beside it"

      listed = rho("acp-agents")
      rows.each_key do |key|
        assert_match(/^agent:     #{Regexp.escape(key)}  #{Regexp.escape(Gem.ruby)} #{Regexp.escape(AGENT)} --mode \S+  (allow|reject)  \d+(\.\d+)?s  .*  enabled$/,
          listed, "the row #{key} is listed:\n#{listed}")
      end
      assert_match(/^  env:     FX_TOKEN=•••$/, listed, "names only, every value masked:\n#{listed}")
      refute_includes listed, SECRET
    end

    # ---- 2. THE FLOOR TURN AND THE CAPTURE ----

    def the_floor_turn_and_the_capture(project)
      conversation, _turn, loop = open_turn("!mock tool_call=#{directive("plain", "hello from rho, the key is #{SECRET}")} -- done", project)
      done = await_loop_status(loop, "completed")
      row = delegate_row(done)
      assert_equal "completed", row.fetch("status"), summarize(done)
      assert_equal "runner", row.dig("addressed_to", "role"), "addressed to rho's runner: #{row.inspect}"
      assert_equal rho_runner_id, row.dig("addressed_to", "executor_public_id")
      output = task_output(loop, row.fetch("key"))
      assert_equal "echo: hello from rho, the key is •••", output.lines.first.strip, "the child's echo, the row's secret erased:\n#{output}"
      refute_includes output, SECRET
      session, stop, calls, refused, capture = trailer(output)
      assert_equal %w[end_turn 0 0], [stop, calls, refused]
      assert_equal File.join(captures_dir(project), "acp", "plain-#{session}.jsonl"), capture,
        "the capture lives in the runner's captures directory under the work dir, keyed by the root — never in the project"

      # THE CAPTURE rides the result as a resource_link; `rho fetch` reads
      # it whole — the handshake, the session, the prompt, the chunks —
      # and never the secret.
      detail = @loops.agent_loop(loop).task(row.fetch("key"))
      link = detail.content.find { |block| block.fetch("type") == "resource_link" }
      refute_nil link, "the capture is linked: #{detail.content.inspect}"
      upload_id = link.fetch("uri").delete_prefix("nexus://uploads/")
      bytes, status = @daemon.cli_bytes("fetch", upload_id)
      assert_predicate status, :success?, bytes.dup.force_encoding(Encoding::UTF_8).scrub
      lines = bytes.force_encoding(Encoding::UTF_8).lines.map { |line| JSON.parse(line) }
      methods = lines.filter_map { |line| line.dig("message", "method") }
      assert_equal %w[initialize session/new session/prompt], methods.select { |m| %w[initialize session/new session/prompt].include?(m) }.uniq
      assert(lines.any? { |line| line.dig("message", "params", "update", "sessionUpdate") == "agent_message_chunk" }, "the chunks are captured")
      refute_includes bytes, SECRET
      assert_equal({ "agent" => "plain", "session" => session, "stopReason" => "end_turn", "calls" => 0, "refused" => 0, "usage" => nil },
        detail.structured_content, "the structure for the UI")

      # THE CHILD lives on past the call, listed with its pid and group.
      listing = rho("acp-agents", "sessions")
      pid = listing[/^session:   #{session}  plain  conversation #{Regexp.escape(conversation)}  pid (\d+)  pgid (\d+)  calls 1  cwd #{Regexp.escape(project)}  capture /, 1]
      refute_nil pid, "the session is listed with its process:\n#{listing}"
      assert alive?(Integer(pid)), "the child lives on past the call"
      await_rho_log(/event=acp\.child_spawned agent=plain conversation=#{Regexp.escape(conversation)} pid=#{pid} pgid=\d+/, "the spawn was never logged")
      [conversation, session, Integer(pid)]
    end

    # ---- 3. THE REUSE AND THE SESSION ----

    def the_child_is_reused_and_a_session_continues(project, conversation, first, pid)
      # A second turn in the SAME conversation rides the same child, on a
      # new session. Every turn here follows the first turn's delegation on
      # the same history, so its script is padded past the answers already
      # there (`behind`).
      loop = say(conversation, "!mock tool_call=#{behind(1, directive("plain", "again"))} -- more")
      done = await_loop_status(loop, "completed")
      output = task_output(loop, delegate_row(done).fetch("key"))
      second, = trailer(output)
      refute_equal first, second, "a call without `session` opens a new session"
      listing = rho("acp-agents", "sessions")
      assert_match(/^session:   #{second}  plain  conversation #{Regexp.escape(conversation)}  pid #{pid}  /, listing,
        "the second session rides the first child:\n#{listing}")
      assert_equal 1, listing.scan(/pid \d+/).uniq.length, "one process for the pair:\n#{listing}"

      # `session` continues one child session: the fixture answers its
      # own session document, whose cwd is the project.
      loop = say(conversation, "!mock tool_call=#{behind(2, directive("plain", "session?", "session" => first))} -- on")
      done = await_loop_status(loop, "completed")
      output = task_output(loop, delegate_row(done).fetch("key"))
      seen = JSON.parse(output.lines.first)
      assert_equal project, seen.fetch("cwd")
      assert_equal 0, seen.fetch("mcpServers"), "rho hands the child no MCP servers"
      continued, = trailer(output)
      assert_equal first, continued

      # A moved workdir on a reused session is refused by name.
      FileUtils.mkdir_p(File.join(project, "sub"))
      loop = say(conversation, "!mock tool_call=#{behind(3, directive("plain", "x", "session" => first, "workdir" => "sub"))} -- moved")
      done = await_loop_status(loop, "completed")
      row = delegate_row(done)
      assert_equal "completed", row.fetch("status"), "a refusal is data: #{summarize(done)}"
      assert_equal "session #{first} works in #{project}; a session's workdir is fixed at its birth — omit `session` to open one in #{File.join(project, "sub")}",
        task_output(loop, row.fetch("key")).strip

      # Another conversation is another child.
      other, _turn, loop = open_turn("!mock tool_call=#{directive("plain", "elsewhere")} -- done", project)
      await_loop_status(loop, "completed")
      listing = rho("acp-agents", "sessions")
      pids = listing.scan(/^session:   \S+  plain  conversation (\S+)  pid (\d+)/).to_h { |c, p| [c, p] }
      refute_equal pids.fetch(conversation), pids.fetch(other), "another conversation is another child:\n#{listing}"
    end

    # ---- 4. THE RELAY ----

    def the_floor_the_policy_and_the_id_only_request(project)
      protected_path = File.join(@home, "settings.json")
      _c, _t, loop = open_turn("!mock tool_call=#{directive("permission", "run npm test\nrun rm -rf /\nedit #{protected_path}")} -- done", project)
      done = await_loop_status(loop, "completed")
      output = task_output(loop, delegate_row(done).fetch("key"))
      assert_equal "allowed:allow\nrejected:reject\nrejected:reject", output.lines.first(3).join.strip, output
      _session, stop, calls, refused, = trailer(output)
      assert_equal %w[end_turn 3 2], [stop, calls, refused]
      await_rho_log(/event=acp\.permission agent=permission kind=execute decision=allow by=policy/, "the allow was never logged")
      assert_match(/event=acp\.permission agent=permission kind=execute decision=reject by=floor reason="recursive delete of a root directory/,
        @daemon.log_text)
      assert_match(/event=acp\.permission agent=permission kind=edit decision=reject by=floor reason="write under \S+ is refused: #{Regexp.escape(INCUBATION)}/,
        @daemon.log_text)

      _c, _t, loop = open_turn("!mock tool_call=#{directive("reject", "run npm test")} -- done", project)
      done = await_loop_status(loop, "completed")
      output = task_output(loop, delegate_row(done).fetch("key"))
      assert_equal "rejected:reject", output.lines.first.strip
      await_rho_log(/event=acp\.permission agent=reject kind=execute decision=reject by=policy/, "the policy's reject was never logged")

      _c, _t, loop = open_turn("!mock tool_call=#{directive("id-only", "run rm -rf /\nrun npm test")} -- done", project)
      done = await_loop_status(loop, "completed")
      output = task_output(loop, delegate_row(done).fetch("key"))
      assert_equal "rejected:reject\nallowed:allow", output.lines.first(2).join.strip, "an id-only request is judged by its tracked tool_call:\n#{output}"
      await_rho_log(/event=acp\.permission agent=id-only kind=execute decision=reject by=floor/, "the tracked call's refusal was never logged")
    end

    # ---- 5. PROGRESS ----

    def progress_reaches_rho_watch(project)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("sleeper", "sleep 4")} -- done", project)
      key = await_delegate_key(loop)
      watcher = @daemon.cli_background("watch", loop, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
      await_loop_status(loop, "completed")
      watched = watcher.read.to_s.force_encoding(Encoding::UTF_8).scrub
      watcher.close
      assert_predicate $?, :success?, "rho watch failed:\n#{watched}"
      assert_match(/^  #{Regexp.escape(key)}\s+│ tick/, watched, "the child's ticks reach the watcher:\n#{watched}")
      assert_match(/^status:\s+completed$/, watched, watched)
    end

    # ---- 6. CANCEL ----

    # The delegation is a fan member of the spine's round, and the kernel
    # cancels by key only a BRANCH (`CancelBranch`: a spine fan member
    # refuses `not_a_branch`; the person's verb for the spine is `stop`) —
    # so the cancel here is the loop's own stop, which the runner's
    # `work_canceled` hands the in-flight call as its cancel signal: one
    # `session/cancel` to the child, the call settled `canceled` under
    # the loop's reason, the turn canceled, the child and its row kept.
    def cancel_keeps_the_child(project)
      conversation, _t, loop = open_turn("!mock tool_call=#{directive("sleeper", "sleep 15")} -- done", project)
      key = await_delegate_key(loop)
      await("the sleeper's call was never claimed") { @daemon.claimed_keys.include?(key) ? true : nil }
      # Keyed on THIS conversation: the progress step's sleeper lives on
      # past its call and is listed first.
      session = await("the sleeper's session never listed") do
        rho("acp-agents", "sessions")[/^session:   (acp-[0-9a-f]{12})  sleeper  conversation #{Regexp.escape(conversation)}  /, 1]
      end
      stopped = rho("stop", conversation)
      assert_match(/^stopped:\s+#{Regexp.escape(conversation)} \(conversation\)$/, stopped,
        "conversation stop cancels its current and background work:\n#{stopped}")
      task = await("the call never canceled") do
        row = loop_row(loop).fetch("tasks").find { |candidate| candidate.fetch("key") == key }
        row if row && row.fetch("status") == "canceled"
      end
      assert_equal "canceled", task.fetch("status")
      assert_equal "loop_canceled", task.dig("error", "key"), task.inspect
      logs = rho("acp-agents", "logs", session)
      lines = logs.lines.map { |line| JSON.parse(line) }
      assert(lines.any? { |line| line.fetch("dir") == "out" && line.dig("message", "method") == "session/cancel" },
        "session/cancel reached the child:\n#{logs}")
      await_rho_log(/event=acp\.cancel_sent agent=sleeper session=#{session}/, "the cancel was never logged")
      listing = rho("acp-agents", "sessions")
      pid = listing[/^session:   #{session}  sleeper  conversation \S+  pid (\d+)/, 1]
      refute_nil pid, "a cancelled call keeps the child and its row:\n#{listing}"
      assert alive?(Integer(pid)), "the child survived the cancel"
      canceled = await_loop_status(loop, "canceled")
      assert_equal "canceled", canceled.dig("turn", "status"), summarize(canceled)
    end

    # ---- 7. THE WALL ----

    def the_wall_kills_the_group(project)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("wall", "sleep 15")} -- done", project)
      pgid = await("the wall's session never listed") do
        rho("acp-agents", "sessions")[/^session:   acp-[0-9a-f]{12}  wall  conversation \S+  pid \d+  pgid (\d+)/, 1]
      end
      done = await_loop_status(loop, "completed")
      row = delegate_row(done)
      assert_equal "completed", row.fetch("status"), "the wall's answer is data: #{summarize(done)}"
      output = task_output(loop, row.fetch("key"))
      assert_match(/delegate_agent timed out after 2 seconds: acp agent "wall"'s process group was killed; its sessions are gone/, output, output)
      _session, stop, = trailer(output)
      assert_equal "timed_out", stop
      assert await_process_group_gone(Integer(pgid), within: GROUP_DEAD_SECONDS), "the wall left the group #{pgid}"
      refute_match(/  wall  /, rho("acp-agents", "sessions"), "the row is gone")
      await_rho_log(/event=acp\.child_killed agent=wall .*pgid=#{pgid}/, "the kill was never logged")
    end

    # ---- 8. DEATH ----

    def a_death_is_answered_by_name(project)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("die", "go")} -- done", project)
      done = await_loop_status(loop, "completed")
      row = delegate_row(done)
      assert_equal "completed", row.fetch("status"), "a death is data: #{summarize(done)}"
      output = task_output(loop, row.fetch("key"))
      assert_match(/\Aabout to go\n\nacp agent "die" exited \(status 3\) during the delegation; its stderr ended: fixture agent: dying with status 3\n/, output)
      session, stop, = trailer(output)
      assert_equal "exited", stop
      refute_match(/  die  /, rho("acp-agents", "sessions"), "the dead child's row is gone")
      await_rho_log(/event=acp\.child_exited agent=die .*exit="status 3"/, "the exit was never logged")

      _c, _t, loop = open_turn("!mock tool_call=#{directive("die", "go", "session" => session)} -- again", project)
      done = await_loop_status(loop, "completed")
      assert_equal "session #{session}'s agent \"die\" exited (status 3); the session is gone — omit `session` to open one",
        task_output(loop, delegate_row(done).fetch("key")).strip, "never revived under the same id"
    end

    # ---- 9. THE DOORS ----

    def the_doors(project)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("auth", "hi")} -- done", project)
      done = await_loop_status(loop, "completed")
      output = task_output(loop, delegate_row(done).fetch("key"))
      assert_equal "echo: hi", output.lines.first.strip, "the row's auth_method logged the child in:\n#{output}"
      session, = trailer(output)
      logs = rho("acp-agents", "logs", session)
      assert_includes logs, %("method":"authenticate")

      _c, _t, loop = open_turn("!mock tool_call=#{directive("terminal", "hi")} -- done", project)
      done = await_loop_status(loop, "completed")
      assert_equal 'acp_auth_required: acp agent "terminal" needs a login this runner cannot perform (its methods: login (terminal)); ' \
                   "run its own program's login by hand, then `rho acp-agents probe terminal`",
        task_output(loop, delegate_row(done).fetch("key")).strip

      _c, _t, loop = open_turn("!mock tool_call=#{directive("elicit", "hi")} -- done", project)
      done = await_loop_status(loop, "completed")
      output = task_output(loop, delegate_row(done).fetch("key"))
      assert_equal "elicitation:decline", output.lines.first.strip
      assert_includes output, "the agent asked: Which colour? — declined; prompt the session again with an answer"

      _c, _t, loop = open_turn("!mock tool_call=#{directive("model", "hi")} -- done", project)
      done = await_loop_status(loop, "completed")
      assert_equal "model:fx-large", task_output(loop, delegate_row(done).fetch("key")).lines.first.strip
    end

    # ---- 10. THE VERBS ----

    def the_verbs(project)
      probed = rho("acp-agents", "probe", "plain")
      pgid = probed[/^agent:     plain  .* connected \(pid \d+, pgid (\d+)\)  protocol 1  acp-fixture-agent 1$/, 1]
      refute_nil pgid, "the probe never connected:\n#{probed}"
      assert_includes probed, "  capabilities: loadSession=false, prompt=text, mcp=none, session=close\n"
      assert_includes probed, "  auth methods: (none)\n"
      assert await_process_group_gone(Integer(pgid), within: GROUP_DEAD_SECONDS), "the probe left its group #{pgid}"

      disabled = rho("acp-agents", "disable", "elicit")
      assert_equal "disabled elicit — the daemon drops it at its next boot (`rho restart`)\n", disabled
      assert_equal false, JSON.parse(File.read(File.join(@home, "settings.json"))).dig("acp_agents", "elicit", "enabled")
      enabled = rho("acp-agents", "enable", "elicit")
      assert_equal "enabled elicit — the daemon offers it at its next boot (`rho restart`)\n", enabled
      assert_equal true, JSON.parse(File.read(File.join(@home, "settings.json"))).dig("acp_agents", "elicit", "enabled")

      _c, _t, loop = open_turn("!mock tool_call=#{directive("plain", "to be killed")} -- done", project)
      done = await_loop_status(loop, "completed")
      session, = trailer(task_output(loop, delegate_row(done).fetch("key")))
      listing = rho("acp-agents", "sessions")
      pid, pgid = listing.match(/^session:   #{session}  plain  conversation \S+  pid (\d+)  pgid (\d+)/)&.captures
      refute_nil pid, listing
      logs = rho("acp-agents", "logs", session)
      assert_includes logs, %("method":"initialize")
      killed = rho("acp-agents", "kill", session)
      assert_equal "killed #{session} (plain, pid #{pid})\n", killed
      assert await_process_group_gone(Integer(pgid), within: GROUP_DEAD_SECONDS), "the kill left the group #{pgid}"
      refute_match(/^session:   #{session}  /, rho("acp-agents", "sessions"), "the killed session is gone")
      refused, status = @daemon.cli("acp-agents", "kill", session)
      refute_predicate status, :success?, "a second kill has nothing to end:\n#{refused}"
      assert_match(/no session #{session} on this daemon/, refused)
    end

    # ---- 11. THE PARK UNDER ASK ----

    def the_park_under_ask(project)
      _c, _t, loop = open_turn("!mock tool_call=#{directive("plain", "held")} -- done", project, "--approval", "ask")
      held = await_park(loop)
      key = held.fetch("key")
      assert_equal "delegate_agent", held.fetch("tool_name")
      inbox = @daemon.control(:get, "/asks").fetch("asks")
      assert_equal 1, inbox.length, inbox.inspect
      assert_equal %w[approval delegate_agent], inbox.first.values_at("kind", "tool_name"), inbox.inspect
      assert_equal({ "agent" => "plain", "prompt" => "held" }, inbox.first.fetch("tool_input"), "the agent and the prompt on the asking line")
      approved = rho("approve", loop, key)
      assert_match(/^approved:\s+#{Regexp.escape(key)}$/, approved, approved)
      done = await_loop_status(loop, "completed")
      assert_equal "completed", done.fetch("tasks").find { |t| t.fetch("key") == key }.fetch("status"), summarize(done)
      assert_equal "echo: held", task_output(loop, key).lines.first.strip
      status = rho("status")
      assert_match(/^approvals:\s+\(none\)$/, status, "a decided call stands on no inbox:\n#{status}")
    end

    # ---- 12. THE CONVERSATION'S END ----

    def the_conversations_end_releases_the_child(conversation, pid)
      assert alive?(pid), "the first conversation's child should be live before the archive"
      chat = @workspace.conversations.conversation(conversation)
      refute_nil chat.archive.archived_at, "archive answers the archived row"
      await_rho_log(/event=acp\.host_ended conversation=#{Regexp.escape(conversation)} children=1/, "the conversation's end never reached the table")
      assert await("the child outlived its conversation") { alive?(pid) ? nil : true }
      refute_match(/conversation #{Regexp.escape(conversation)}  /, rho("acp-agents", "sessions"), "the conversation's rows are gone")
    end

    # ---- 13. NO ROWS, NO TOOL ----

    def no_rows_no_tool(project)
      @daemon.stop
      write_settings(rows: {})
      restart!
      runner = rho("runner")
      refute_match(/delegate_agent/, runner, "no row, no tool:\n#{runner}")
      refute_match(/^FAILED:/, runner, "the extension loads clean without a row:\n#{runner}")
      await_rho_log(/event=acp\.no_agent_enabled rows=0/, "the tool-less load was never logged")
      assert_equal "", rho("acp-agents"), "no row to list"
      note = File.join(project, "note.txt")
      File.write(note, "still served\n")
      _c, _t, loop = open_turn("!mock tool_call=read tool_args=#{CGI.escape(JSON.generate("path" => note))} -- done", project)
      done = await_loop_status(loop, "completed")
      assert_includes task_output(loop, done.fetch("tasks").find { |task| task["tool_name"] == "read" }.fetch("key")), "still served"
    end

    # ---- the settings ----

    def rows
      @rows ||= {
        "plain" => fixture("plain", "env" => { "FX_TOKEN" => "${FX_TOKEN}" }),
        "permission" => fixture("permission"),
        "reject" => fixture("permission", "permissions" => "reject"),
        "id-only" => fixture("id_only"),
        "sleeper" => fixture("sleep"),
        "wall" => fixture("sleep", "timeout_ms" => WALL_TIMEOUT_MS),
        "die" => fixture("die"),
        "auth" => fixture("auth_required", "auth_method" => "fixture-login"),
        "terminal" => fixture("terminal_auth_only"),
        "elicit" => fixture("elicit"),
        "model" => fixture("model_option", "model" => "fx-large"),
      }
    end

    def fixture(mode, **extra)
      { "command" => Gem.ruby, "args" => [AGENT, "--mode", mode], "description" => "the #{mode} fixture agent" }.merge(extra)
    end

    def write_settings(rows:)
      File.write(File.join(@home, "settings.json"),
        JSON.pretty_generate(E2E::RhoDaemon::DEV_SETTINGS.merge("extensions" => ["rho/acp-client", "rho/dev"], "acp_agents" => rows)))
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
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # `rho say`: the loop of the turn it opened.
    def say(conversation, prompt)
      output = rho("say", conversation, prompt, "--model", MODEL)
      loop = output[/^loop:\s+(\S+)/, 1]
      refute_nil loop, "rho say printed no loop:\n#{output}"
      loop
    end

    # THE DIRECTIVE, as the mock parses it: `delegate_agent:<url-encoded json>`.
    def directive(agent, prompt, **fields)
      "delegate_agent:#{CGI.escape(JSON.generate({ "agent" => agent, "prompt" => prompt }.merge(fields)))}"
    end

    # THE MOCK'S CLOCK IS THE HISTORY (support/mock_llm/app.rb, `answers_in`):
    # which call a round makes is the count of tool answers the whole
    # input already carries, and a later turn on the same conversation
    # carries every earlier turn's answer — so a one-call script behind
    # one delegation is spent before the round reads it, and the round
    # speaks. A turn `answered` delegations deep is padded to that index,
    # the way provider_override_test pads; the padding is never reached.
    def behind(answered, call) = ([call] * (answered + 1)).join(",")

    def trailer(output)
      match = output.match(TRAILER)
      refute_nil match, "no trailer line:\n#{output}"
      match.captures
    end

    def delegate_row(done)
      row = done.fetch("tasks").find { |task| task["tool_name"] == "delegate_agent" }
      refute_nil row, summarize(done)
      row
    end

    def await_delegate_key(loop)
      await("the delegation never appeared on the loop") do
        loop_row(loop).fetch("tasks").find { |task| task["tool_name"] == "delegate_agent" }&.fetch("key")
      end
    end

    # ---- the world ----

    def connect!
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

    AGENT_ANNOUNCED = /event=executor\.announced tools=\d+ address=agent\b/

    def agent_announcement_count = @daemon.log_text.scan(AGENT_ANNOUNCED).length

    def await_agent_announced(after:)
      @daemon.await("the agent address never announced its tools") { agent_announcement_count > after ? true : nil }
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

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def process_group_alive?(pgid)
      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      # macOS answers EPERM for a group of nothing but zombies: not gone
      # until its leader is reaped, which is the table's `kill_and_reap`.
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

  # Where the runner places a root's captures: under the world's RHO_WORK_DIR (the fixture leaves
  # the default, RHO_HOME/work), keyed by the root's digest — the same placement `Daemon.boot`
  # wires.
  def captures_dir(project)
    Rho::Runner::ToolEnv.artifacts_dir_for(root: project, work_dir: File.join(@daemon.home, "work"))
  end
end
