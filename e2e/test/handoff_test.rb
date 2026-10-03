require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "time"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/session_sign_in_budget"

# THE HANDOFF. A host's runner binding is the host's, moved only by an explicit verb — a Human's
# through the SDK, rho's through `rho handoff` — and the kernel re-addresses, through its one
# addressing site, exactly the rows nobody has claimed. One full-mode rho on this machine beside H,
# the harness runner, granted ACCOUNT-WIDE by the founding owner (eligible for the steward AND for
# rho's agent) and announcing `read grep slow_read slow_write` with a root of its own.
#
# Handoff after the old runner is gone: a person hands off BECAUSE the old runner is gone. rho's
# runner takes every listed row the moment it is nudged, so an unclaimed row on a LIVE runner is a
# race; on a runner that was KILLED it is a fact. The steward's standalone loop names the dead H;
# its two rows park unclaimed; the steward's SDK handoff to rho's runner re-addresses `read` (rho's
# real `read` answers with the file, its clock re-armed at now + the kernel default), fails
# `slow_read` `tool_not_served` at once through FailNode (absorb: resolved by policy), and the loop
# completes.
#
# X3-A, mid-fan through the SDK on a rho conversation: the claimed rows
# settle on rho, untouched; the conversation's next turn lands on H — H's
# echoes, H's root in the lead, `bash` withheld from the turn's names and
# refused if guessed — and rho REPORTS the byte collision (H's `grep` and
# `read` in other bytes; the first name says so) it did not get to refuse
# (a Human's handoff is never rho's to veto).
#
# E-COLLISION: two hosts on two runners, each turn offered its runner's
# names — proven by effect, the way a model would meet it: the name the
# host's runner serves runs there; the other runner's name is refused
# `unknown_tool` by the compile door. The union declares `read` once
# (rho's bytes) and grows by H's two slow tools alone.
#
# THE CLI CASE (drive the CLI, not the route): `rho handoff` back to rho's
# own runner moves the next `bash` home; `rho handoff` onto H is refused
# `declaration_conflict` naming the colliding tool, the binding unchanged. LAST, a
# revoked H is refused `runner_not_eligible` naming why.
class HandoffTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  # A FRESH KEY UNDER THE OWNER: the steward's `cybros-e2e-executor` is
  # another manager's registration, and its scope is the steward's private
  # one — this runner must be account-wide to serve rho's agent.
  RUNNER_IDENTIFIER = "e2e-handoff-runner".freeze
  RUNNER_DISPLAY_NAME = "E2E handoff runner".freeze
  # Two names rho's Coding announces too (`read`, `grep` — the collision,
  # reported by its FIRST name in declaration order: `grep`), two it does
  # not (the union's whole growth).
  ECHO_TOOLS = %w[read grep slow_read slow_write].freeze
  # Coding's `read` announces no timeout: a re-addressed row takes the
  # kernel's default park (`AgentLoopNodes::ToolTask::DEFAULT_TIMEOUT_MS`).
  DEFAULT_PARK_SECONDS = 600
  # The harness runner's own announced clock (`EchoTools::TIMEOUT_MS`).
  ECHO_PARK_SECONDS = 30
  CONFLICT_SENTENCE = "grep is declared with different bytes by this rho and by %s; " \
    "a handoff would offer the model two readings of one name".freeze
  TROUBLE = /runner_task_failed|runner_submit_refused/

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @actor = E2E::BrowserActor.new(@base_url)
    @owner = E2E::BrowserActor.new(@base_url)
    @device = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    @home = Dir.mktmpdir("rho-handoff-e2e")
    @executor_home = Dir.mktmpdir("e2e-handoff-runner")
    @h_root = File.join(@executor_home, "tree")
    FileUtils.mkdir_p(@h_root)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    @process = nil
    sign_in(@actor, email: @steward.email, password: @steward.password)
    sign_in(@owner, email: @world.owner_email, password: @world.owner_password)
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      warn_log(@process&.log_path, "harness runner log")
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/handoff-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture handoff E2E capture: #{error.class}: #{error.message}"
  ensure
    stop_quietly("the harness runner") { @process&.stop }
    stop_quietly("the rho daemon") { @daemon&.stop }
    @actor&.close
    @owner&.close
    [@home, @executor_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_a_handoff_readdresses_what_nobody_claimed_and_the_next_turn_lands_on_the_new_runner
    boot_rho
    @process = grant_and_start_harness_runner
    the_harness_runner_is_discoverable_with_its_root

    an_unclaimed_row_on_a_dead_runner_is_readdressed_through_the_sdk
    a_mid_fan_handoff_through_the_sdk_moves_the_next_turn_and_reports_the_collision
    two_hosts_on_two_runners_are_each_offered_their_runners_names
    the_cli_hands_a_host_back_and_refuses_the_collision
    a_revoked_target_is_refused_by_name
  end

  private

    LOOP_POLL = 1
    FEED_POLL = 1
    AWAIT_SECONDS = 120

    # ---- the phases ----

    # Discovery is how a person finds a runner: the account-wide H is listed for the steward with
    # what it announced — its names and its root — and presence rides it as display alone.
    def the_harness_runner_is_discoverable_with_its_root
      listed = @steward_client.executors.list(kind: "runner")
      assert_includes listed.map(&:public_id), @rho_runner, "discovery lists rho's own runner for its steward"
      named = @steward_client.executors.show(@h)
      assert_equal "account_wide", named.assignment_scope, "the owner's grant made H account-wide: #{named.inspect}"
      assert_equal ECHO_TOOLS.sort, named.tool_names.sort
      assert_equal @h_root, named.environment["root"], "the announced root reads back through discovery"
      assert_equal "Relative paths resolve against #{@h_root}.", named.environment.dig("fragments", 0, "text")
      assert_includes %w[offline not_yet_seen], named.presence,
        "the harness runner polls and opens no socket: never online — shown, never a reason to choose"
    end

    # X3-B. H is killed — not stopped, not revoked: its row stays live,
    # announced and listed. The steward's loop names it; both rows park
    # `dispatched` addressed to H and nobody claims them. Then the handoff.
    def an_unclaimed_row_on_a_dead_runner_is_readdressed_through_the_sdk
      @process.kill!
      assert_includes @steward_client.executors.list(kind: "runner").map(&:public_id), @h,
        "the dead H is still listed by discovery — the lever this half turns on"

      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      marker = "read-by-rhos-runner-after-the-handoff-#{SecureRandom.hex(4)}"
      note = File.join(project, "handoff-note.txt")
      File.write(note, "#{marker}\n")

      loop_id = author_and_start(@h, [
        { parallel: [
          { tool: { key: "r1", name: "read", input: { path: note } } },
          { tool: { key: "s1", name: "slow_read", input: { seconds: 1 }, on_failure: "absorb" } },
        ] },
        { model: { key: "m1", model: { model: MODEL }, prompt: "!mock -- report what the tools said" } },
      ])
      parked = await("both rows never parked for the dead H", every: 0.5) do
        row = loop_row(loop_id)
        tasks = %w[r1 s1].map { |key| task_of(row, key) }
        row if tasks.all? { |task| task && task["status"] == "dispatched" && task.dig("addressed_to", "executor_public_id") == @h }
      end
      %w[r1 s1].each do |key|
        refute task_of(parked, key).key?("claimed_by"), "nobody claimed #{key}: the process is dead — #{summarize(parked)}"
      end
      dispatched_at = task_of(parked, "r1")["started_at"]&.then { |stamp| Time.iso8601(stamp) } || Time.now

      # THE VERB, through the SDK, as the Human who owns the loop.
      handoff_at = Time.now
      bound = @steward_client.workspace(@workspace_public_id).agent_loop(loop_id).bind_runner(executor_public_id: @rho_runner)
      assert_equal @rho_runner, bound.runner.executor_public_id, "the 200 carries the binding: #{bound.runner.inspect}"
      assert_equal "online", bound.runner.presence, "rho's own runner holds a pong-verified socket"

      events = await("the loop feed never carried the re-address", every: FEED_POLL) do
        items = feed(loop_path(loop_id))
        items if items.any? { |item| item["type"] == "task_readdressed" && item.dig("payload", "task_key") == "r1" }
      end
      bound_item = events.find { |item| item["type"] == "runner_bound" }
      refute_nil bound_item, "no runner_bound on the loop's own feed: #{types(events)}"
      assert_equal({ "executor_public_id" => @rho_runner, "previous_executor_public_id" => @h, "by" => @steward.public_id },
        bound_item.fetch("payload"), "the binding moved from the dead H to rho's runner, by the steward")
      readdressed = events.find { |item| item["type"] == "task_readdressed" && item.dig("payload", "task_key") == "r1" }
      assert_equal "runner", readdressed.dig("payload", "role")
      assert_equal @rho_runner, readdressed.dig("payload", "executor_public_id"), readdressed.inspect
      deadline = Time.iso8601(readdressed.dig("payload", "deadline_at"))
      # THE CLOCK RE-ARMED: the row parked on H's short clock; re-addressed, its deadline is the
      # re-arm instant plus the NEW runner's timeout — the kernel default, since Coding's `read`
      # announces none — never a clock H's timeout could have reached.
      assert_operator deadline, :>, dispatched_at + ECHO_PARK_SECONDS + 60,
        "the deadline was not re-armed: #{deadline.iso8601} against a dispatch at #{dispatched_at.iso8601}"
      assert_in_delta handoff_at.to_f + DEFAULT_PARK_SECONDS, deadline.to_f, 30,
        "the deadline is the handoff instant plus the new runner's park (#{deadline.iso8601})"
      refute(events.any? { |item| item["type"] == "task_readdressed" && item.dig("payload", "task_key") == "s1" },
        "a name the new runner lacks is failed, never re-addressed: #{types(events)}")

      completed = await_loop_status(loop_id, "completed")
      read_task = task_of(completed, "r1")
      assert_equal "completed", read_task.fetch("status"), summarize(completed)
      assert_equal @rho_runner, read_task.dig("addressed_to", "executor_public_id"), "the row now names rho's runner"
      assert_equal({ "executor_public_id" => @rho_runner }, read_task.fetch("claimed_by"), "rho's runner took it")
      assert_includes task_output(loop_id, "r1"), marker, "rho's REAL `read` answered with the file, not an echo"
      assert_includes @daemon.claimed_keys, "r1", "rho's own log says it claimed the re-addressed row: #{@daemon.claims.inspect}"

      slow_task = task_of(completed, "s1")
      assert_equal "failed", slow_task.fetch("status"), summarize(completed)
      assert_equal({ "key" => "tool_not_served", "detail" => "no executor announces slow_read for this principal" },
        slow_task.fetch("error"), "the Refusal arm: rho's runner lacks `slow_read`, nobody else serves it")
      assert_equal "absorb", slow_task.fetch("on_failure"), "FailNode honoured the row's on_failure"
      refute slow_task.key?("failure_resolution"), "absorb resolves by policy, never by a stamp"
      assert_equal "completed", task_of(completed, "m1").fetch("status"), "the absorbed failure released the round: #{summarize(completed)}"

      # the re-address narrated `task_readdressed` ALONE — no same-status `task_status` beside it.
      # r1's status items after the settle: two `dispatched` (H's dispatch, then rho's claim, which
      # re-narrates the unmoved status), never a third for the re-address.
      r1_statuses = feed(loop_path(loop_id))
        .select { |item| item["type"] == "task_status" && item.dig("payload", "task_key") == "r1" }
        .map { |item| item.dig("payload", "status") }
      assert_equal 2, r1_statuses.count("dispatched"),
        "the re-address narrated a task_status the row's status does not justify: #{r1_statuses.inspect}"
      assert_equal "completed", r1_statuses.last, r1_statuses.inspect

      # `rho relay` FOLLOWS THE NEW BINDING: a request named on rho's runner is addressed to it and
      # claimed by rho — the row a handoff would move is the row a relay lands on.
      relayed, relay_status = @daemon.cli("relay", @rho_runner, "read", JSON.generate("path" => note))
      assert_predicate relay_status, :success?, "rho relay failed:\n#{relayed}"
      relay_loop = relayed[/^loop:\s+(\S+)/, 1]
      refute_nil relay_loop, relayed
      assert_match(/^task:\s+relay \(tool_task\) completed$/, relayed)
      assert_includes relayed, marker, "rho's REAL `read` answered the relay with the file"
      relay_row = task_of(loop_row(relay_loop), "relay")
      assert_equal @rho_runner, relay_row.dig("addressed_to", "executor_public_id"), "addressed to the new binding"
      assert_equal({ "executor_public_id" => @rho_runner }, relay_row.fetch("claimed_by"))
      assert_includes @daemon.claimed_keys, "relay", "rho's own log says it claimed the relay: #{@daemon.claims.inspect}"

      # H comes back on the same credential: no grant, the same root.
      @process.start
      assert_equal @h, @process.executor_public_id
      assert_equal @h_root, @process.announced_environment_root
    end

    # X3-A. Turn 1 on rho's own runner fans `bash` (four seconds) and `read`
    # through the kernel's own fan (`g.parallel`); both claimed by rho, the
    # steward hands the CONVERSATION to H mid-flight. Claimed rows settle
    # where they started; turn 2 lands on H whole.
    def a_mid_fan_handoff_through_the_sdk_moves_the_next_turn_and_reports_the_collision
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      marker = "settled-on-rho-#{SecureRandom.hex(4)}"
      note = File.join(project, "fan-note.txt")
      File.write(note, "fanned-read-#{marker}\n")
      # `wait: true`: this case is about CLAIMS mid-fan, not the WHEN default — the fan must run
      # inside the turn for the handoff to land mid-flight.
      script = CGI.escape(JSON.generate({ "script" =>
        "g.parallel([g.tool({ name: \"bash\", input: { command: \"sleep 4; echo #{marker}\" } }), " \
        "g.tool({ name: \"read\", input: { path: #{JSON.generate(note)} } })]);", "wait" => true }))
      claims_before = @daemon.claims.length
      # Turn 2 echoes its complete request to prove the new runner's lead. Keep this earlier
      # reply short so an unrelated copy of the full policy does not force that proof to compact.
      @conversation, _turn, loop_id, output = rho_do("!mock tool_call=compose tool_args=#{script} reply=fan-complete -- fan out", project, "--compose")
      refute_match(/^runner:/, output, "rho's OWN runner prints no slot line (local truth is `rho status`'s):\n#{output}")

      # BOTH CLAIM LINES before the handoff — the fan is claimed, so it is
      # untouchable; `bash` is still sleeping when the binding moves.
      claimed = await("rho never claimed both fanned rows", every: 0.2) do
        fresh = @daemon.claims.drop(claims_before)
        fresh if fresh.map { |claim| claim["tool"] }.sort == %w[bash read]
      end
      @declared_before_handoff = declarations.length
      bound = @steward_client.workspace(@workspace_public_id).conversation(@conversation).bind_runner(executor_public_id: @h)
      assert_equal @h, bound.runner.executor_public_id, "the 200 names H: #{bound.runner.inspect}"
      assert_equal @h, @steward_client.workspace(@workspace_public_id).conversation(@conversation).fetch.runner.executor_public_id,
        "the conversation read carries the binding"

      completed = await_loop_status(loop_id, "completed")
      fanned = completed.fetch("tasks").select { |task| %w[bash read].include?(task["tool_name"]) }
      assert_equal %w[bash read], fanned.map { |task| task["tool_name"] }.sort, summarize(completed)
      fanned.each do |task|
        assert_equal "completed", task.fetch("status"), "a claimed row settles where it started: #{task.inspect}"
        assert_equal({ "executor_public_id" => @rho_runner }, task.fetch("claimed_by"), task.inspect)
        assert_equal @rho_runner, task.dig("addressed_to", "executor_public_id"), "claimed rows are never re-addressed"
      end
      assert_includes task_output(loop_id, fanned.find { |t| t["tool_name"] == "bash" }.fetch("key")), marker, "the shell ran here"
      assert_includes task_output(loop_id, fanned.find { |t| t["tool_name"] == "read" }.fetch("key")), "fanned-read-#{marker}",
        "rho's real `read` answered, not H's echo"
      assert_equal claimed.map { |claim| claim["task"] }.sort, fanned.map { |task| task["key"] }.sort,
        "the two claims rho logged are the two fanned rows"

      events = feed(conversation_path(@conversation))
      bound_item = events.find { |item| item["type"] == "runner_bound" }
      refute_nil bound_item, "no runner_bound on the conversation feed: #{types(events)}"
      assert_equal({ "executor_public_id" => @h, "previous_executor_public_id" => @rho_runner, "by" => @steward.public_id },
        bound_item.fetch("payload"))
      refute(events.any? { |item| item["type"] == "task_readdressed" },
        "nothing was unclaimed, so nothing was re-addressed: #{types(events)}")

      # rho FOLLOWS the handoff it did not make: the row moves, the collision is REPORTED by its
      # first name (H's `grep` and `read` differ from Coding's bytes), and the union is re-declared
      # once — by `slow_read` and `slow_write` alone; `grep` and `read` keep rho's bytes.
      followed = await("rho never followed the runner_bound item", every: 0.5) do
        @daemon.log_lines.find { |line| line["event"] == "host.runner_bound" && line["host"] == @conversation }
      end
      assert_equal @h, followed["executor"]
      assert_equal @rho_runner, followed["previous"]
      assert_equal @steward.public_id, followed["by"]
      assert_equal "grep", followed["conflict"], "a Human's handoff onto colliding bytes is reported, never refused: #{followed.inspect}"

      # Turn 2: the mock calls `grep`, then `read`, then guesses `bash`.
      # Turn 2's history renders turn 1's compose answer, and the mock
      # counts answers across the whole input, so the script is padded by
      # one to reach its first call (the conversation journey's precedent).
      grep_args = CGI.escape(JSON.generate({ "pattern" => "marker", "path" => "." }))
      read_args = CGI.escape(JSON.generate({ "path" => "note.txt" }))
      bash_args = CGI.escape(JSON.generate({ "command" => "echo never" }))
      said, status = @daemon.cli("say", @conversation,
        "!mock tool_call=grep:#{grep_args},grep:#{grep_args},read:#{read_args},bash:#{bash_args} -- say what you found")
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      assert_match(/^runner:\s+#{Regexp.escape(@h)} offline \(last seen \d+[smhd] ago\) — tool calls wait for it; rho handoff moves them$/,
        said, "the three-state slot for a FOREIGN runner that polls (offline):\n#{said}")

      second_loop = await_next_turn_loop(@conversation, loop_id)
      turn = await_loop_status(second_loop, "completed")
      %w[grep read].each do |name|
        task = turn.fetch("tasks").find { |row| row["tool_name"] == name }
        refute_nil task, "the model never called #{name}: #{summarize(turn)}"
        assert_equal "completed", task.fetch("status"), task.inspect
        assert_equal({ "role" => "runner", "executor_public_id" => @h, "presence" => "offline" },
          task.fetch("addressed_to").except("last_seen_at"), "the next round's calls land on H")
        assert_equal({ "executor_public_id" => @h }, task.fetch("claimed_by"))
        assert_includes task_output(second_loop, task.fetch("key")), "echo:#{name}:", "H's echo answered"
      end
      guessed = turn.fetch("tasks").find { |row| row["tool_name"] == "bash" }
      refute_nil guessed, "the model never guessed bash: #{summarize(turn)}"
      assert_equal %w[failed unknown_tool], [guessed.fetch("status"), guessed.dig("error", "key")],
        "`bash` is withheld from a turn bound to H — the narrowed `tool_names` — and refused if guessed: #{guessed.inspect}"
      assert_includes @process.claimed_keys, turn.fetch("tasks").find { |row| row["tool_name"] == "grep" }.fetch("key"),
        "H's own log says it took the row: #{@process.claims.inspect}"
      # THE LEAD NAMES H's ROOT: the mock echoes what it was shown, and the
      # inline lead rho re-rendered for the new binding rides behind
      # history as turn 2's preface — turn 1's local lead stays where
      # turn 1 sent it, so the local root appears
      # only BEFORE H's, which is the newest lead the model read.
      assert_lead_names(@h_root, spoken_text(second_loop, turn), "turn 2's lead is the remote runner's announced snapshot")
    end

    # E-COLLISION. Host A on rho's own runner, host B on H — opened by
    # `rho do --runner`. Each turn is offered its runner's names: the
    # other's is refused `unknown_tool`. The union: one declaration since
    # the follow, grown by exactly the two names H alone serves.
    def two_hosts_on_two_runners_are_each_offered_their_runners_names
      project = File.join(@home, "project")
      bash_args = CGI.escape(JSON.generate({ "command" => "echo on-rho" }))
      slow_args = CGI.escape(JSON.generate({ "seconds" => 1 }))

      @host_a, _turn, loop_a, = rho_do("!mock tool_call=bash:#{bash_args},slow_read:#{slow_args} -- done", project)
      @host_b, _turn, loop_b, output_b = rho_do("!mock tool_call=slow_read:#{slow_args},bash:#{bash_args} -- done", project,
        "--runner", @h)
      assert_match(/^runner:\s+#{Regexp.escape(@h)} offline/, output_b, "B's slot names H:\n#{output_b}")

      a = await_loop_status(loop_a, "completed")
      assert_served(a, "bash", on: @rho_runner)
      assert_refused_unknown(a, "slow_read")
      assert_includes task_output(loop_a, task_named(a, "bash").fetch("key")), "on-rho"

      b = await_loop_status(loop_b, "completed")
      assert_served(b, "slow_read", on: @h)
      assert_refused_unknown(b, "bash")
      assert_includes task_output(loop_b, task_named(b, "slow_read").fetch("key")), "echo:slow_read:"
      assert_lead_names(@h_root, spoken_text(loop_b, b), "a host opened on H reads H's root in its lead")

      declared = declarations
      boot = Integer(declared.first.fetch("tools"), 10)
      since_handoff = declared.drop(@declared_before_handoff)
      assert_equal 1, since_handoff.length,
        "the union is declared ONCE on the follow and never per turn: #{since_handoff.inspect}"
      assert_equal boot + 2, Integer(since_handoff.first.fetch("tools"), 10),
        "the union grew by slow_read and slow_write alone — read and grep keep rho's bytes"

      # `rho runners`: H's row carries the kernel's presence word, its root,
      # the two hosts bound to it and the reported collision; rho's own row
      # is marked; the legend closes it.
      listed, status = @daemon.cli("runners")
      assert_predicate status, :success?, "rho runners failed:\n#{listed}"
      h_line = listed.lines.find { |line| line.include?(@h) }
      refute_nil h_line, "`rho runners` never listed H:\n#{listed}"
      assert_match(/\A  #{Regexp.escape(@h)}  #{Regexp.escape(RUNNER_DISPLAY_NAME)}  offline \(last seen \d+[smhd] ago\)  root #{Regexp.escape(@h_root)}  tools 4  bound: .*  conflict: grep$/,
        h_line, listed)
      [@conversation, @host_b].each { |host| assert_includes h_line[/bound: (.*?)  conflict/, 1], host, h_line }
      own_line = listed.lines.find { |line| line.include?(@rho_runner) }
      assert_match(/\A= #{Regexp.escape(@rho_runner)}  /, own_line, "this machine's own runner is marked:\n#{listed}")
      assert_match(/^\* selected in settings  = this machine's own$/, listed)

      # `rho processes`: the table of every runner a followed host is bound to is read THROUGH the
      # relay (`list_processes`), and a runner that cannot answer is ONE line naming it and the
      # error — H announces no `list_processes`, so the request fails `tool_not_served` at start; no
      # host line, no "not in this table" sentence.
      shown, status = @daemon.cli("processes")
      assert_predicate status, :success?, "rho processes failed:\n#{shown}"
      assert_includes shown, "runner #{@h} could not answer: tool_not_served"
      refute_includes shown, "not in this table", "the honest line went with the relay:\n#{shown}"
    end

    # THE CLI CASE. `rho handoff B rho's-runner` (own bytes, no conflict): the printed move, ONE
    # tree-sync warning (H announced a root of its own, rho's runner announces this machine's — the
    # roots differ, no branch on either side to compare — never a refusal), B's read names rho's
    # runner, the next `bash` lands here. `rho handoff A H`: refused `declaration_conflict` naming
    # the first colliding tool, exit 1, A's binding unchanged.
    def the_cli_hands_a_host_back_and_refuses_the_collision
      handed, status = @daemon.cli("handoff", @host_b, @rho_runner)
      assert_predicate status, :success?, "rho handoff failed:\n#{handed}"
      assert_equal "handed off: #{@host_b} → #{@rho_runner} (was #{@h})", handed.lines.first.chomp
      assert_equal 1, handed.lines.count { |line| line.include?("the tree is not synced") },
        "the tree-sync warning appears exactly once:\n#{handed}"
      assert_equal "warning:   old runner #{@h} at #{@h_root}, new runner #{@rho_runner} at #{local_root} — the tree is not synced",
        handed.lines[1].chomp, "the differing fields, and only them:\n#{handed}"
      refute_match(/^runner:/, handed, "rho's own runner is online: no slot line\n#{handed}")
      assert_equal @rho_runner, @steward_client.workspace(@workspace_public_id).conversation(@host_b).fetch.runner.executor_public_id

      # B's history carries its first turn's two answers (the served
      # `slow_read`, the refused `bash`), and the mock counts answers across
      # the whole input: padded so a `bash` call is reached whatever the count.
      bash_args = CGI.escape(JSON.generate({ "command" => "echo back-on-rho" }))
      loops_before = loop_ids_of(@host_b)
      said, status = @daemon.cli("say", @host_b, "!mock tool_call=bash:#{bash_args},bash:#{bash_args},bash:#{bash_args} -- done")
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      refute_match(/^runner:/, said, "back on this machine's own runner, the slot is silent:\n#{said}")
      next_loop = await("B's next turn never opened", every: FEED_POLL) { (loop_ids_of(@host_b) - loops_before).first }
      row = await_loop_status(next_loop, "completed")
      assert_served(row, "bash", on: @rho_runner)
      assert_includes task_output(next_loop, task_named(row, "bash").fetch("key")), "back-on-rho"
      assert_includes @daemon.claimed_keys, task_named(row, "bash").fetch("key"), "rho's own log holds the claim"

      refused, status = @daemon.cli("handoff", @host_a, @h)
      refute_predicate status, :success?, "a colliding handoff must exit 1:\n#{refused}"
      assert_includes refused, format(CONFLICT_SENTENCE, @h), refused
      assert_equal @rho_runner, @steward_client.workspace(@workspace_public_id).conversation(@host_a).fetch.runner.executor_public_id,
        "A's binding is unchanged by a refused handoff"
      refute(feed(conversation_path(@host_a)).any? { |item| item["type"] == "runner_bound" },
        "the refusal happened before any kernel call: no runner_bound on A")
    end

    # A REVOKED TARGET, last (H is needed live above): the owner revokes
    # H's credentials from their console; a handoff onto it is refused
    # `runner_not_eligible` naming why, and the bindings already made stand.
    def a_revoked_target_is_refused_by_name
      @owner.visit("/runners")
      page = @owner.page
      page.assert_text(RUNNER_DISPLAY_NAME)
      page.find("tr", text: RUNNER_DISPLAY_NAME).click_button("Revoke credentials")
      page.find("#turbo-confirm[open] button[value='confirm']").click
      page.assert_text("Credentials revoked. The machine keeps its identity.")

      fresh = @steward_client.workspace(@workspace_public_id).conversations.create(idempotency_key: SecureRandom.uuid)
      refused = assert_raises(CybrosAgent::Api::Conflict) do
        @steward_client.workspace(@workspace_public_id).conversation(fresh.public_id).bind_runner(executor_public_id: @h)
      end
      assert_equal "runner_not_eligible", refused.code
      assert_includes refused.message, "no ready credential", refused.message
      assert_equal @rho_runner, @steward_client.workspace(@workspace_public_id).conversation(@host_a).fetch.runner.executor_public_id,
        "rho's own bindings are untouched by a refused target"
      refute_match TROUBLE, @daemon.log_text, "rho's runner met a refusal or a failure"
    end

    # ---- the harness: one rho, the owner's grant, one process ----

    def boot_rho
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      adopted = await_workspace_state("adopted")
      @workspace_public_id = adopted.dig("workspace", "public_id")
      @rho_runner = adopted.dig("identity", "runner_executor_public_id")
      refute_nil @rho_runner, "a full-mode rho registers a runner row: #{adopted["identity"].inspect}"
      await_rho_announced
      E2E.enable_dev_lane!
      E2E.hosts.start
    end

    # THE ACCOUNT-WIDE GRANT: the founding owner walks the machine page — the selector is theirs —
    # so H is eligible for the steward's loops AND for rho's agent's hosts. One budget consume; the
    # credential reaches the child on stdin; the root rides argv.
    def grant_and_start_harness_runner
      E2E::DeviceAuthorizationBudget.consume
      authorization = @device.request_runner_authorization(
        runner_identifier: RUNNER_IDENTIFIER, runner_display_name: RUNNER_DISPLAY_NAME
      )
      assert_equal :runner, authorization.branch
      E2E::RunnerGrant.visit_connection(actor: @owner, authorization: authorization)
      case (offer = E2E::RunnerGrant.scope_offer(@owner))
      when :selector
        E2E::RunnerGrant.connect_in_browser(actor: @owner, authorization: authorization, account_wide: true)
      when :account_wide
        E2E::RunnerGrant.connect_in_browser(actor: @owner, authorization: authorization, existing_runner_scope: :account_wide)
      else
        flunk "the handoff runner must be account-wide, and the owner's page offered #{offer.inspect}"
      end
      credentials = @device.await_credentials(authorization)
      assert_nil credentials.access_token, "a machine is a delivery address, never a member principal"

      process = E2E::ExecutorProcess.new(base_url: @base_url, home: @executor_home,
        credential: credentials.executor_access_token, tools: ECHO_TOOLS, environment: @h_root)
      process.start
      assert_equal ECHO_TOOLS.sort, process.announced.sort, "the process announced what it was asked to"
      assert_equal @h_root, process.announced_environment_root, "the process announced its root"
      @h = process.executor_public_id
      process
    end

    # `rho do`, the shipped verb: the conversation, its turn, the loop
    # backing it, and the whole output for the slot line.
    def rho_do(prompt, project, *flags)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project, *flags)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids + [output]
    end

    # The person's own shape over the member plane: the named runner on the
    # shell, the steps, started at once.
    def author_and_start(runner_executor_public_id, steps)
      path = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops"
      body, code = agent_api_post(path, { "agent_loop" => {
        "runner_executor_public_id" => runner_executor_public_id, "steps" => steps,
        "approval_mode" => "bypass",
      } })
      assert_equal 201, code, "authoring the loop: #{body}"
      loop_id = body.dig("agent_loop", "public_id")
      _, started = agent_api_post("#{path}/#{loop_id}/start", {})
      assert_equal 200, started, "starting the loop"
      loop_id
    end

    def await_rho_announced
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
    end

    # ---- reads ----

    def assert_served(row, name, on:)
      task = task_named(row, name)
      refute_nil task, "the model never called #{name}: #{summarize(row)}"
      assert_equal "completed", task.fetch("status"), task.inspect
      assert_equal on, task.dig("addressed_to", "executor_public_id"), "#{name} was addressed elsewhere: #{task.inspect}"
      assert_equal({ "executor_public_id" => on }, task.fetch("claimed_by"), task.inspect)
    end

    def assert_refused_unknown(row, name)
      task = task_named(row, name)
      refute_nil task, "the model never guessed #{name}: #{summarize(row)}"
      assert_equal %w[failed unknown_tool], [task.fetch("status"), task.dig("error", "key")],
        "#{name} is the OTHER runner's: withheld from this turn's names and refused if guessed — #{task.inspect}"
    end

    def task_named(row, name) = row.fetch("tasks").find { |task| task["tool_name"] == name }

    # Every `profile.declared` line rho wrote, oldest first — the boot's
    # first, then one per change of the union's bytes.
    def declarations = @daemon.log_lines.select { |line| line["event"] == "profile.declared" }

    # The turn opened with the remote runner's lead: it is the NEWEST lead
    # in what the model was shown — each turn's lead rides behind history
    # as that turn's preface, so an earlier turn's local lead (and its
    # echo) stays where that turn sent it, ahead of this one, and never
    # comes after it. (The kernel's memory block may precede the leads; it
    # names no root.)
    def assert_lead_names(root, spoken, message)
      remote = spoken.rindex("Relative paths resolve against #{root}.")
      refute_nil remote, "#{message}: #{spoken.lstrip[0, 300].inspect}"
      assert_equal remote, spoken.rindex("Relative paths resolve against "),
        "#{message}: this turn's lead is the newest the model read: #{spoken.lstrip[0, 300].inspect}"
      local = spoken.rindex("Relative paths resolve against #{local_root}")
      assert(local.nil? || local < remote,
        "#{message}: a local lead came after the remote runner's: #{spoken.lstrip[0, 300].inspect}")
    end

    def local_root = @local_root ||= @daemon.control(:get, "/environment").dig("environment", "root")

    # WHAT THE MODEL WAS SHOWN, off the mock's own echo: a round that calls
    # a tool speaks nothing, so the turn's words are on its LAST model
    # round — every round's request carried the same lead.
    def spoken_text(loop_id, row)
      row.fetch("tasks").select { |task| task.fetch("kind") == "model_task" }
        .map { |task| task_output(loop_id, task.fetch("key")) }.join("\n")
    end

    def task_of(row, key) = row.fetch("tasks").find { |task| task.fetch("key") == key }

    def loop_path(loop_id) = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops/#{loop_id}"

    def conversation_path(conversation) = "/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}"

    def loop_row(loop_id)
      document = agent_api(loop_path(loop_id))
      document.fetch("agent_loop") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def await_loop_status(loop_id, status)
      await("the loop #{loop_id} never reached #{status}", every: LOOP_POLL) do
        row = loop_row(loop_id)
        row if row["status"] == status
      end
    end

    def task_output(loop_id, key) = agent_api("#{loop_path(loop_id)}/tasks/#{key}").dig("task", "output").to_s

    # The loops that back a conversation's turns, in feed order.
    def loop_ids_of(conversation)
      feed(conversation_path(conversation))
        .select { |item| item["type"] == "turn_status" }
        .filter_map { |item| item.dig("payload", "agent_loop_public_id") }.uniq
    end

    def await_next_turn_loop(conversation, previous_loop)
      await("the next turn never opened on #{conversation}", every: FEED_POLL) do
        (loop_ids_of(conversation) - [previous_loop]).first
      end
    end

    # The whole event window of a host, oldest first.
    def feed(path)
      items = []
      after = nil
      loop do
        page = agent_api("#{path}/events?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def types(items) = items.map { |item| item["type"] }.inspect

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
    end

    def await(message, every: 0.5)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name: the
    # test process inherits the machine's empty locale.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def agent_api_post(path, body)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid
      request.body = JSON.generate(body)
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      text = response.body.to_s.force_encoding(Encoding::UTF_8)
      [JSON.parse(text.empty? ? "{}" : text), response.code.to_i]
    end

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    # One sign-in per browser: the steward's for the ceremony, the owner's
    # for the account-wide grant and the revoke — two of the shared budget.
    def sign_in(actor, email:, password:)
      page = actor.page
      actor.visit("/session/new")
      page.fill_in "Email", with: email
      page.fill_in "Password", with: password
      E2E::SessionSignInBudget.consume
      page.click_button "Sign in"
      assert page.has_text?("Dashboard")
    end

    def stop_quietly(label)
      yield
    rescue StandardError => error
      warn "Could not stop #{label}: #{error.class}: #{error.message}"
    end

    LOG_TAIL_LINES = 120

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
