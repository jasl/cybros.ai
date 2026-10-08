require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "shellwords"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"

# THE EXECUTOR PLANE, driven by something that is not rho. Every rho journey proves the plane with
# rho on both sides — the daemon announces, the daemon's own runner claims. These put a SECOND
# executor beside it: a harness process holding ONLY a transport credential from the browser grant,
# announcing echo handlers, listing, claiming and committing on the executor plane with no member
# standing at all.
#
# E2: a rho that announces nothing opens a turn naming the process on
# `rho run --runner`; the binding is the process and the call lands there.
# E3: rho and the process both announce `read`; rho's own address is the
# binding and wins; the process's inbox stays empty and nothing declines.
# E4: the executor socket is switched off; three tool rounds complete on
# the sweep alone and the meters say so — `nudged: 0` beside `swept > 0`.
# E9: a THIRD executor of the other machine kind — a tools provider — is
# the only announcer of `find`; the call is a POOL row addressed to the
# role, the provider claims it, and the task read names it as claimant.
#
# SHARED PLUMBING, STATED: every test in this file drives the SAME signed-in
# steward browser (E2E::StewardSession, one per journey process); the
# daemon, its RHO_HOME and every ceremony stay per test.
class ExecutorPlaneTest < Minitest::Test
  EMPTY_PRELUDE = File.expand_path("../support/empty_extensions_prelude.rb", __dir__)
  MODEL = "dev/mock-text".freeze
  # ONE RUNNER REGISTRATION for every case in this file: the same
  # (manager, identifier) key re-pairs the same address, whatever order the
  # cases run in, so the id a case names on `rho run --runner` is one live
  # row and never a leftover. Its manager is the rho steward, so the
  # private scope a member gets is exactly the eligibility rho's agent
  # needs (the kernel infers no binding — r-modes M6 — so every case names).
  REGISTRATION_IDENTIFIER = "cybros-e2e-executor".freeze
  RUNNER_DISPLAY_NAME = "E2E executor".freeze
  # ONE PROVIDER REGISTRATION, under its OWN key: the registration key is
  # kind-blind on disk (one live address per (manager, identifier) across
  # BOTH kinds), so a provider re-pairing the runner's identifier would be
  # refused. A provider is never a binding, so it leaves E2's rule alone.
  PROVIDER_IDENTIFIER = "cybros-e2e-provider".freeze
  PROVIDER_DISPLAY_NAME = "E2E provider".freeze
  # The four read-only echoes, named: the process serves what it is asked
  # to, and E2's `announced == tools` pin stays byte-identical whatever the
  # harness's full set grows to (the slow tools are the expiry journey's).
  ECHO_TOOLS = %w[find grep ls read].freeze
  # The runner's log lines that would say a claim went wrong (rho-runner's
  # `Runner#take` and `TaskRun#answer`); E3 pins their absence on both sides.
  TROUBLE = /runner_task_failed|runner_submit_refused/

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @client = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    @home = Dir.mktmpdir("rho-executor-plane-e2e")
    @executor_home = Dir.mktmpdir("e2e-executor-process")
    @provider_home = Dir.mktmpdir("e2e-provider-process")
    @daemon = nil
    @process = nil
    @provider = nil
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log")
      warn_log(@process&.log_path, "executor process log")
      warn_log(@provider&.log_path, "provider process log")
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/executor_plane-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture executor plane E2E capture: #{error.class}: #{error.message}"
  ensure
    stop_quietly("the provider process") { @provider&.stop }
    stop_quietly("the executor process") { @process&.stop }
    stop_quietly("the rho daemon") { @daemon&.stop }
    [@home, @executor_home, @provider_home, @project].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # E2. A rho whose extension set holds no tool announces `[]` and serves
  # nothing; its profile still declares the echo tools (the prelude's
  # addition — the round's gate admits only declared names). rho in AGENT
  # MODE (r-modes M1) registers no runner row, so it NAMES the process on
  # `rho run --runner` — the kernel infers no binding (r-modes M6), and an
  # unnamed host would fail `read` as `tool_not_served`. The host binds the
  # named process, `read` is addressed
  # there (the row says so), and the answer on the transcript is the
  # process's echo — rho had no handler that could have produced it.
  def test_a_runner_process_serves_a_core_only_rho_turn
    File.write(File.join(@home, "settings.json"),
      JSON.generate({ "settings_version" => 1, "plugins" => { "rho.codemode" => { "enabled" => false } } }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: agent_mode_prelude_env)
    workspace_public_id = boot_rho
    # The address may still carry an earlier journey's announcement until
    # this daemon's `[]` lands; the binding is computed at the turn's
    # start, so the turn waits for the daemon's own record of it.
    await_rho_log(/event=executor\.announced tools=0\b/, "the empty announcement never landed")
    helped, status = @daemon.cli("help")
    assert_predicate status, :success?, helped
    refute_match(/^  rho runner\b/, helped, "an empty extension set installs no `runner` verb:\n#{helped}")
    assert_match(/^  rho run \[PROMPT\]/, helped, "the one conversation verb is the core's:\n#{helped}")
    %w[do watch].each { |verb| refute_match(/^  rho #{verb}\b/, helped, "`#{verb}` is rho-dev's, not this product home's:\n#{helped}") }

    @process = grant_and_start_executor(tools: ECHO_TOOLS)

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    read = runner_callable("read", workspace_public_id: workspace_public_id, runner: @process.executor_public_id, project: project)
    loop_id = rho_run("!mock tool_call=#{read} tool_args=#{CGI.escape(JSON.generate({ "path" => "x" }))} -- say what you read",
      project, runner: @process.executor_public_id)
    completed = await_loop_completion(workspace_public_id, loop_id)
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{summarize(completed)}"
    assert_equal "read", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), tool_task.inspect
    # The addressee's presence rides the trace (r-modes M4): the harness
    # process polls and opens no socket, so it reads `offline` while working —
    # honest, and the poll model is untouched.
    assert_equal({ "role" => "runner", "executor_public_id" => @process.executor_public_id, "presence" => "offline" },
      tool_task.fetch("addressed_to").except("last_seen_at"), "the row was addressed to the runner rho named")
    refute_nil tool_task.dig("addressed_to", "last_seen_at"), "the process's polls stamped contact"

    output = task_output(workspace_public_id, loop_id, tool_task.fetch("key"))
    assert_includes output, "echo:read:", "the process's echo handler answered: #{output.inspect}"
    assert_includes output, '"path":"x"', "the echo carried the model's arguments: #{output.inspect}"

    assert_operator @process.claimed, :>=, 1,
      "the process's own meters say it took the work: #{@process.statuses.last.inspect}"
    refute_match TROUBLE, rho_log, "rho's runner met a refusal or a failure on a row it never held"
  end

  # E3. Two announcers of one tool. rho under its ordinary set — full mode,
  # its own runner row — announces `read` (Coding's) on that row; the
  # process announces `read` too. THE RUNNER RHO NAMED WINS: `rho run` names
  # rho's own runner row for the host (the setting, else its own), so the
  # call is addressed to it, the answer is the FILE's content (rho's real
  # `read`), the process's inbox holds nothing for it, and no decline line
  # appears in either log — the runner no longer has a decline path to take.
  def test_two_announcers_of_one_tool_the_bound_address_wins_and_nothing_declines
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    workspace_public_id = boot_rho
    await_rho_announced
    rho_runner = @daemon.status.dig("identity", "runner_executor_public_id")
    refute_nil rho_runner, "a full-mode rho registers its own runner row: #{@daemon.status["identity"].inspect}"

    @process = grant_and_start_executor(tools: %w[read])

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    marker = "bound-address-#{SecureRandom.hex(4)}"
    note = File.join(project, "note.txt")
    File.write(note, "#{marker}\n")
    loop_id = rho_run("!mock tool_call=read tool_args=#{CGI.escape(JSON.generate({ "path" => note }))} -- say what you read",
      project)
    completed = await_loop_completion(workspace_public_id, loop_id)
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{summarize(completed)}"
    assert_equal "read", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), tool_task.inspect
    # rho's own runner row holds a pong-verified socket: `online` (r-modes M4).
    assert_equal({ "role" => "runner", "executor_public_id" => rho_runner, "presence" => "online" },
      tool_task.fetch("addressed_to").except("last_seen_at"),
      "the row was addressed to the runner rho named — its own")

    output = task_output(workspace_public_id, loop_id, tool_task.fetch("key"))
    assert_includes output, marker, "rho's own `read` answered with the file: #{output.inspect}"
    refute_includes output, "echo:", "the process never touched the row: #{output.inspect}"

    assert_equal 0, @process.claimed,
      "the process's inbox held nothing for this turn: #{@process.statuses.last.inspect}"
    assert_operator @process.statuses.length, :>=, 1, "the process never swept"
    refute_match TROUBLE, @process.log_text, "the process declined or failed a row it was never addressed"
    refute_match TROUBLE, rho_log, "rho declined or failed a row"

    runner = runner_snapshot
    assert_operator runner.fetch("claimed"), :>=, 1, "rho's runner did the work: #{runner.inspect}"
  end

  # E4. The cable is latency only: with the executor socket off (`RHO_EXECUTOR_SOCKET=0`, the
  # Rho::Config knob), a turn of three tool rounds completes on the sweep alone, and `rho runner`
  # reads the diagnosis pair — `nudged: 0` beside a rising `swept` and `claimed: 3`.
  def test_the_cable_killed_the_sweep_converges_and_nudged_stays_zero
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: { "RHO_EXECUTOR_SOCKET" => "0" })
    workspace_public_id = boot_rho
    await_rho_announced

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    marker = SecureRandom.hex(4)
    calls = %w[one two three].map do |word|
      "bash:#{CGI.escape(JSON.generate({ "command" => "echo #{word}-#{marker}" }))}"
    end
    loop_id = rho_run("!mock tool_call=#{calls.join(",")} -- done", project)
    completed = await_loop_completion(workspace_public_id, loop_id)
    fanned = completed.fetch("tasks").select { |task| task.fetch("kind") == "tool_task" }
    assert_equal 3, fanned.length, "the model asked three times: #{summarize(completed)}"
    assert fanned.all? { |task| task.fetch("status") == "completed" }, "rho ran every one of them: #{summarize(completed)}"
    outputs = fanned.map { |task| task_output(workspace_public_id, loop_id, task.fetch("key")) }
    %w[one two three].each do |word|
      assert outputs.any? { |out| out.include?("#{word}-#{marker}") }, "the shell never ran step #{word}: #{outputs.inspect}"
    end

    printed, status = @daemon.cli("runner")
    assert_predicate status, :success?, printed
    meters = printed[/^claimed:.*$/]
    refute_nil meters, "`rho runner` printed no meters line:\n#{printed}"
    read = ->(name) { Integer(meters[/\b#{name}:\s+(\d+)/, 1] || flunk("`rho runner` printed no #{name}:\n#{printed}"), 10) }
    assert_equal 0, read.call("nudged"), "the socket was off, so nothing could have nudged:\n#{printed}"
    assert_equal 3, read.call("claimed"), "every round was claimed by the sweep:\n#{printed}"
    assert_operator read.call("swept"), :>, 0, "the sweep carried the work:\n#{printed}"
  end

  def test_http_only_force_stop_reaps_a_silent_tool_and_the_next_turn_recovers
    File.write(File.join(@home, "settings.json"), JSON.generate({ "settings_version" => 1, "plugins" => {} }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: { "RHO_EXECUTOR_SOCKET" => "0" })
    workspace_id = boot_rho
    await_rho_announced
    @project = Dir.mktmpdir("rho-http-cancellation-project")
    pgid_path = File.join(@project, "pgid")
    command = "ps -o pgid= -p $$ | tr -d ' ' > #{Shellwords.escape(pgid_path)}; sleep 60"
    prompt = "!mock tool_call=bash tool_args=#{CGI.escape(JSON.generate({ "command" => command }))} -- wait"
    opened = @daemon.control(:post, "/conversations", body: {
      "prompt" => prompt, "model" => MODEL, "working_directory" => @project,
      "environment" => { "root" => @project, "directories" => [] },
    })
    conversation_id = opened.dig("conversation", "public_id")
    loop_id = opened.dig("run", "public_id")
    refute_nil conversation_id, opened.inspect
    refute_nil loop_id, opened.inspect
    pgid = @daemon.await("the silent shell never wrote its process group") do
      File.file?(pgid_path) ? File.read(pgid_path).strip[/\A\d+\z/] : nil
    end.to_i
    assert process_group_alive?(pgid), "the claimed shell must be running before force stop"

    stopped = @daemon.control(:post, "/stop", body: { "public_id" => loop_id, "force" => true })
    assert_equal conversation_id, stopped.dig("stopped", "public_id"), stopped.inspect
    assert_equal "conversation", stopped.dig("stopped", "host_type"), stopped.inspect
    assert process_group_gone?(pgid, within: 8),
      "HTTP recovery did not reap the silent shell's group within a five-second check plus cleanup margin"

    loop_path = "/agent_api/v1/workspaces/#{workspace_id}/runs/#{loop_id}"
    canceled = await_result("the force-stopped loop never settled") do
      row = agent_api(loop_path).fetch("run")
      row if row.fetch("status") == "canceled"
    end
    tool = canceled.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool, canceled.inspect
    assert_equal "canceled", tool.fetch("status")
    assert_equal "run_canceled", tool.dig("error", "key")
    meters = await_result("the runner never finished its canceled execution") do
      row = runner_snapshot
      row if row.fetch("canceled") == 1 && row.fetch("claimed") == 1
    end
    assert_equal 1, meters.fetch("claimed")
    assert_equal 1, meters.fetch("canceled")
    assert_equal 0, meters.fetch("nudged"), "the cancellation was recovered without an executor socket"
    assert_operator meters.fetch("swept"), :>, 0

    said = @daemon.control(:post, "/say", body: {
      "public_id" => conversation_id, "text" => "!mock -- what happened", "delivery_mode" => "steer",
    })
    refute_nil said.dig("input", "public_id"), said.inspect
    events_path = "/agent_api/v1/workspaces/#{workspace_id}/conversations/#{conversation_id}/events?limit=200"
    next_turn = await_result("the next turn never completed after HTTP cancellation") do
      agent_api(events_path).fetch("events").find do |event|
        event["type"] == "turn_status" && event.dig("payload", "status") == "completed" &&
          event.dig("payload", "run_public_id") != loop_id
      end
    end
    next_loop = next_turn.dig("payload", "run_public_id")
    assert_includes task_output(workspace_id, next_loop, "r1"),
      "<tool_use_error>The tool call was aborted before it completed. (run_canceled)</tool_use_error>"
    assert_equal 1, runner_snapshot.fetch("canceled"), "the canceled execution was counted once"
    refute_match TROUBLE, rho_log, "the late canceled answer must not fail or replace the kernel's terminal state"
  end

  # E9. THE POOL. rho under the empty prelude (agent mode) announces nothing; the runner process
  # announces `read grep ls` and, named on `rho run --runner`, is the binding; a PROVIDER process —
  # the other machine kind, connected under its own key by the same steward — announces `find`
  # alone. The model calls `find`: nobody bound announced it, so the row is a pool row —
  # `addressed_to` names the role and no executor — listed for every eligible provider until one
  # claims it. The provider's echo is on the transcript (only it could have produced `echo:find:`),
  # the task read names the provider as claimant (the public-id snapshot), and neither the runner
  # process nor rho ever held it.
  def test_a_tool_provider_claims_a_pool_addressed_call_and_is_named_as_claimant
    File.write(File.join(@home, "settings.json"),
      JSON.generate({ "settings_version" => 1, "plugins" => { "rho.codemode" => { "enabled" => false } } }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: agent_mode_prelude_env)
    workspace_public_id = boot_rho
    await_rho_log(/event=executor\.announced tools=0\b/, "the empty announcement never landed")

    @process = grant_and_start_executor(tools: %w[grep ls read])
    @provider = grant_and_start_executor(tools: %w[find], kind: :tool_provider,
      identifier: PROVIDER_IDENTIFIER, display_name: PROVIDER_DISPLAY_NAME, home: @provider_home)
    assert_equal "tool_provider", @provider.announced_kind, "the address carries the kind the grant named"
    assert_equal "runner", @process.announced_kind

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    loop_id = rho_run("!mock tool_call=find tool_args=#{CGI.escape(JSON.generate({ "path" => "src" }))} -- say what you found",
      project, runner: @process.executor_public_id)
    completed = await_loop_completion(workspace_public_id, loop_id)
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{summarize(completed)}"
    assert_equal "find", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), tool_task.inspect
    key = tool_task.fetch("key")

    detail = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}/tasks/#{key}").fetch("task")
    assert_includes detail.fetch("output").to_s, "echo:find:", "the provider's echo answered: #{detail["output"].inspect}"
    assert_includes detail.fetch("output").to_s, '"path":"src"'
    assert_equal({ "role" => "tool_provider" }, detail.fetch("addressed_to"),
      "a pool row: the role alone, no executor — #{detail.inspect}")
    assert_equal({ "executor_public_id" => @provider.executor_public_id }, detail.fetch("claimed_by"),
      "the provider is named as claimant")
    refute detail.key?("effect_profile"), "never the effect profile on the member read"

    assert_includes @provider.claimed_keys, key, "the provider's own log says it took the row"
    assert_empty @process.claimed_keys, "the runner process announced no `find`: it was never a member"
    assert_equal 0, @process.claimed, @process.statuses.last.inspect
    refute_includes rho_log, "event=runner_task_claimed", "rho announced nothing and held nothing"
    refute_match TROUBLE, @provider.log_text, "the provider met a refusal or a failure"
    refute_match TROUBLE, @process.log_text, "the runner process declined or failed a row it was never addressed"
    refute_match TROUBLE, rho_log, "rho's runner met a refusal or a failure"
  end

  # THE CLAIMANT'S EXTENSION, END TO END (node review 2026-09-08, change
  # 8). The process announces `slow_read` on a thirty-second park; the
  # model asks for a 25-second one. Under the clamp alone the runner would
  # answer "timed out" at 22.5 s; a handler with no clamp of its own is
  # extended instead — the process asks the kernel at half its park, the
  # kernel moves the ONE clock and narrates it (`task_deadline_extended`:
  # the key, the new deadline, the claimant, the ask), the daemon fans
  # that frame to whoever follows, and the echo lands as a completed
  # answer under `rho run`'s own deadline. THE STREAM IS THE READ, NOT
  # THE ROW: the daemon keeps `extension_ms` on a task only until its
  # status next moves (`host_run.rb`, `commit_task` rebuilds the row
  # without it), so a row read after the settle never carries the ask;
  # rho-dev's `watch` printed it off the row DURING the park, and what a
  # product home has of that moment is `run`'s own stream — every frame
  # verbatim under `--output-format stream-json`.
  def test_a_runner_extends_a_slow_handler_past_its_park_and_the_stream_says_so
    File.write(File.join(@home, "settings.json"),
      JSON.generate({ "settings_version" => 1, "plugins" => { "rho.codemode" => { "enabled" => false } } }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: agent_mode_prelude_env)
    workspace_public_id = boot_rho
    await_rho_log(/event=executor\.announced tools=0\b/, "the empty announcement never landed")
    @process = grant_and_start_executor(tools: ECHO_TOOLS + %w[slow_read])

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    arguments = CGI.escape(JSON.generate({ "seconds" => SLOW_SECONDS }))
    slow_read = runner_callable("slow_read", workspace_public_id: workspace_public_id, runner: @process.executor_public_id, project: project)
    frames, result = rho_run_stream("!mock tool_call=#{slow_read} tool_args=#{arguments} -- say what happened", project,
      "--timeout", "120", runner: @process.executor_public_id)
    loop_id = result.fetch("run_id")
    refute_nil loop_id, "the result names the loop it ran: #{result.inspect}"
    extended = frames.find { |frame| frame["type"] == "task_deadline_extended" }
    refute_nil extended, "the stream carries the runner's ask beside the park it extends: #{frames.map { |frame| frame["type"] }.inspect}"
    assert_equal EXTENSION_SECONDS * 1000, extended.fetch("timeout_ms"), extended.inspect
    assert_equal @process.executor_public_id, extended.fetch("by"), "the ask names the claimant: #{extended.inspect}"

    completed = await_loop_completion(workspace_public_id, loop_id)
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called the tool: #{summarize(completed)}"
    assert_equal "slow_read", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), "the extension carried it past the clamp: #{tool_task.inspect}"
    output = task_output(workspace_public_id, loop_id, tool_task.fetch("key"))
    assert_includes output, "echo:slow_read:", "the handler finished and answered: #{output.inspect}"
    refute_includes output, "timed out", "never the clamp's answer: #{output.inspect}"

    extended = @process.since_start.select { |line| line["event"] == "runner_task_extended" }
    assert_operator extended.length, :>=, 1, "the process asked the kernel for more time: #{@process.statuses.last.inspect}"
    assert_equal tool_task.fetch("key"), extended.first.fetch("task")
    assert_equal tool_task.fetch("key"), frames.find { |frame| frame["type"] == "task_deadline_extended" }.fetch("task_key"),
      "the frame names the park it extends"
    assert_equal E2E::EchoTools::SlowRead::TIMEOUT_MS, extended.first.fetch("timeout_ms"),
      "the ask is the tool's own park: the class's `TIMEOUT_MS`, the number the served Tool carries and announced (F-4)"
    refute_match(/runner_extension_refused/, @process.log_text, "every ask was granted")
    refute_match TROUBLE, @process.log_text, "the process met a refusal or a failure"
  end

  def test_removed_answerer_loses_both_planes_and_its_conversation_is_force_stopped
    E2E::DeviceAuthorizationBudget.consume
    authorization = @client.request_authorization(
      agent_identifier: "cybros-e2e-removal-#{SecureRandom.hex(4)}",
      agent_display_name: "E2E removal probe", executor_display_name: "E2E removal app"
    )
    E2E::Ceremony.confirm(actor: @actor, started: {
      "verification_uri_complete" => authorization.verification_uri_complete,
      "user_code" => authorization.user_code, "branch" => "agent",
    })
    planes = CybrosAgent.planes_for(@client.await_credentials(authorization), base_url: @base_url)
    profile_id = planes.client.profile.fetch.member.public_id
    executor = planes.executor_client
    tool_name = "profile_removal_probe"
    planes.client.profile.declare_configuration(
      tool_definitions: [{
        "type" => "function",
        "function" => { "name" => tool_name, "parameters" => { "type" => "object", "properties" => {} } },
      }],
      approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "default", compaction_policy: nil
    )
    executor.announce(tools: [{ "name" => tool_name, "effect_profile" => E2E::EchoTools::READ_ONLY }])

    # A Human-created conversation must stop when its answerer is removed.
    human = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    workspace = human.workspace(human.workspaces.create(
      name: "Profile removal #{SecureRandom.hex(4)}", access_mode: "account_wide", idempotency_key: SecureRandom.uuid
    ).workspace.public_id)
    chat = workspace.conversations.conversation(workspace.conversations.create(
      answering_user_public_id: profile_id, idempotency_key: SecureRandom.uuid
    ).public_id)
    E2E.enable_dev_lane!
    E2E.hosts.start
    chat.inputs.create(kind: "direct_reply", model: MODEL,
      text: "!mock tool_call=#{tool_name},#{tool_name} -- finished", idempotency_key: SecureRandom.uuid)
    first = await_result("the first tool never reached the answerer's inbox") do
      executor.inbox.list.items.find { |task| task.conversation_public_id == chat.public_id }
    end
    door = executor.inbox_task(run_public_id: first.run_public_id, task_key: first.task_key)
    claimed = door.claim

    @actor.visit("/agents/#{profile_id}")
    @page.click_button "Remove"
    @page.find("#turbo-confirm button[value='confirm']").click
    assert @page.has_text?("Agent removed.")
    assert_raises(CybrosAgent::Api::Unauthorized) { planes.client.profile.fetch }
    assert_raises(CybrosAgent::Api::Unauthorized) { executor.executor.executor }
    assert_raises(CybrosAgent::Api::Unauthorized) do
      door.commit(claim_token: claimed.claim_token, content: "late result")
    end

    context = workspace.run(first.run_public_id)
    stopped = await_result("the removed answerer's loop never stopped") do
      state = context.fetch
      state if state.status == "canceled"
    end
    assert_equal "canceled", stopped.status
    task = context.fetch.tasks.find { |candidate| candidate.key == first.task_key }
    assert_equal "canceled", task.status
    assert_equal "run_canceled", task.error.fetch("key")
    assert_equal 1, context.fetch.tasks.count { |candidate| candidate.kind == "tool_task" },
      "force stop never schedules another tool round"
  end

  private

    LOOP_POLL = 1
    AWAIT_SECONDS = 120
    # Longer than the clamp's 22.5 s of the slow read's thirty-second park
    # (its class's `TIMEOUT_MS`), shorter than the park once extended.
    SLOW_SECONDS = 25
    EXTENSION_SECONDS = E2E::EchoTools::SlowRead::TIMEOUT_MS / 1000

    # The EMPTY prelude loads no runner tool, and a full-mode boot refuses
    # to serve nothing (r-modes M1) — so those boots are agent mode, said
    # through the child's environment the way a container would say it.
    def agent_mode_prelude_env = { "RUBYOPT" => "-r#{EMPTY_PRELUDE}", "RHO_MODE" => "agent" }

    def boot_rho
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      E2E.enable_dev_lane!
      E2E.hosts.start
      await_workspace_state("adopted").dig("workspace", "public_id")
    end

    # THE GRANT, then the process: the transport credential comes only through the browser ceremony
    # a person completes, one budget consume per grant, and reaches the child on stdin. The same
    # ceremony for either machine kind — the request names it, the page says it, and the scope block
    # is the runner's.
    def grant_and_start_executor(tools:, kind: :runner, identifier: REGISTRATION_IDENTIFIER,
                                 display_name: RUNNER_DISPLAY_NAME, home: @executor_home)
      E2E::DeviceAuthorizationBudget.consume
      authorization = @client.request_runner_authorization(
        registration_identifier: identifier, runner_display_name: display_name, executor_kind: kind.to_s
      )
      assert_equal :runner, authorization.branch, "the branch is the credential's shape for both kinds"
      assert_equal kind.to_s, authorization.executor_kind
      E2E::RunnerGrant.visit_connection(actor: @actor, authorization: authorization)
      # The steward is a plain member, so a fresh registration is PRIVATE to
      # the profiles they manage — rho's agent among them, which is all the
      # eligibility E2 (and a pool's membership, E9) needs; the same key
      # connected again by a sibling case re-pairs it and inherits that scope.
      offer = E2E::RunnerGrant.scope_offer(@actor)
      inherited = offer if %i[account_wide user_private].include?(offer)
      E2E::RunnerGrant.connect_in_browser(actor: @actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
      credentials = @client.await_credentials(authorization)
      assert_nil credentials.access_token, "a machine is a delivery address, never a member principal"

      process = E2E::ExecutorProcess.new(base_url: @base_url, home: home,
        credential: credentials.executor_access_token, kind: kind, tools: tools)
      process.start
      assert_equal tools.sort, process.announced.sort, "the process announced what it was asked to"
      process
    end

    # `rho run`, the shipped verb, followed to its end, and the id of the
    # loop backing the turn off its header; `runner` names the runner-kind
    # executor the turn's tools run on.
    def rho_run(prompt, project, *flags, runner: nil)
      output, status = @daemon.cli("run", prompt, "--model", MODEL, "--dir", project,
        *(["--runner", runner] if runner), *flags)
      assert_predicate status, :success?, "rho run failed:\n#{output}"
      loop_id = output[/^run:\s+(\S+)/, 1]
      refute_nil loop_id, output
      loop_id
    end

    # Read the callable from a real accepted declaration. The fixture names the
    # served tool and target while rho owns the public callable's spelling.
    def runner_callable(name, workspace_public_id:, runner:, project:)
      run_id = rho_run("!mock usage=100:5 reply=ready -- discover this Runner's tools", project, runner: runner)
      task = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{run_id}/tasks/r1").fetch("task")
      entry = task.fetch("tool_definitions").find do |tool|
        tool.dig("route", "runner_executor_public_id") == runner && tool.dig("route", "tool_name") == name
      end
      refute_nil entry, "the accepted declaration has no #{name} for #{runner}: #{task.fetch("tool_definitions").inspect}"
      entry.fetch("function").fetch("name")
    end

    # The same verb under `--output-format stream-json`: every frame the
    # daemon fanned, parsed in order, and the result object last — its
    # `loop_id` stands where the text header's `loop:` line would.
    def rho_run_stream(prompt, project, *flags, runner: nil)
      output, status = @daemon.cli("run", prompt, "--model", MODEL, "--dir", project,
        *(["--runner", runner] if runner), "--output-format", "stream-json", *flags)
      assert_predicate status, :success?, "rho run failed:\n#{output}"
      frames = output.lines.map { |line| JSON.parse(line) }
      result = frames.pop
      assert_equal "result", result&.fetch("type", nil), "the result object ends the stream:\n#{output}"
      [frames, result]
    end

    def runner_snapshot
      @daemon.control(:get, "/runner").fetch("runner")
    end

    def process_group_alive?(pgid)
      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def process_group_gone?(pgid, within:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        return true unless process_group_alive?(pgid)

        sleep 0.2
      end
      !process_group_alive?(pgid)
    end

    # rho's address announced its whole toolset before this turn can be
    # addressed to it (the daemon announces synchronously before it
    # follows, and reports the count on `GET /runner`).
    def await_rho_announced
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
    end

    def await_rho_log(pattern, message)
      @daemon.await(message) { rho_log.match?(pattern) ? true : nil }
    end

    def rho_log
      path = File.join(@home, "log", "rho.log")
      File.file?(path) ? File.read(path, encoding: Encoding::UTF_8) : ""
    end

    def await_result(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        result = yield
        return result if result

        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep LOOP_POLL
      end
    end

    def await_loop_completion(workspace_public_id, loop_id)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}")
        found = latest["run"]
        return found if found && found["status"] == "completed"
        flunk "the loop never completed; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep LOOP_POLL
      end
    end

    def task_output(workspace_public_id, loop_id, key)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}/tasks/#{key}")
        .dig("task", "output").to_s
    end

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
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

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    # The shared steward session (E2E::StewardSession) signed in once for
    # this file; each test lands on the dashboard and asserts it — the same
    # assertion the per-test sign-in made, now against the shared session.
    def sign_in_steward
      @actor.visit("/")
      assert @page.has_text?("Dashboard")
    end

    def stop_quietly(label)
      yield
    rescue StandardError => error
      warn "Could not stop #{label}: #{error.class}: #{error.message}"
    end

    def warn_log(path, label)
      warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
    end
end
