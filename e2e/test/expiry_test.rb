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

# EXPIRY, ON A RUNNER THAT DIES MID-CLAIM. The harness process claims a slow echo tool and is KILLED
# — not stopped: a stop answers the claim, a death leaves it to the kernel's clock. Past the
# announced deadline the sweep settles the row by the tool's frozen effect profile, and nothing
# re-queues itself (decision 8):
#
# (a) `slow_read`, replayable: `timed_out`/`tool_timeout`. The model's fan
#     absorbs it, the continuation reads "exceeded its deadline", the loop
#     completes; the process restarted on the same credential claims
#     nothing — the row was never put back.
# (b) `slow_write`, an open-world write on a client-authored `halt` step:
#     `uncertain`/`tool_uncertain` — its effect may have happened, so the
#     loop HOLDS for a person. `rho watch` names the word and the two verbs;
#     `rho retry` is the person deciding it did not happen: the row is
#     re-queued under a new generation, re-addressed to the same binding,
#     and the restarted process runs it to `completed`.
#
# One rho under the empty prelude (Ops's verbs, no tools), one process
# announcing every echo tool, two grants for the file, one restart.
class ExpiryTest < Minitest::Test
  EMPTY_PRELUDE = File.expand_path("../support/empty_extensions_prelude.rb", __dir__)
  MODEL = "dev/mock-text".freeze
  # The same (manager, identifier) key as the executor-plane journey: one
  # runner registration, re-paired, so the process stays the SOLE eligible
  # runner the host binds.
  RUNNER_IDENTIFIER = "cybros-e2e-executor".freeze
  RUNNER_DISPLAY_NAME = "E2E executor".freeze
  # Longer than the announced park (30 s) by a margin the clamp cannot
  # close either: the process is killed while the handler still sleeps.
  SLOW_SECONDS = 20
  UNCERTAIN_HINT = "effect uncertain: check, then `rho retry` or `rho abandon`".freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @client = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    @home = Dir.mktmpdir("rho-expiry-e2e")
    @executor_home = Dir.mktmpdir("e2e-expiry-executor")
    @daemon = nil
    @process = nil
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log")
      warn_log(@process&.log_path, "executor process log")
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/expiry-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture expiry E2E capture: #{error.class}: #{error.message}"
  ensure
    stop_quietly("the executor process") { @process&.stop }
    stop_quietly("the rho daemon") { @daemon&.stop }
    @actor&.close
    [@home, @executor_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_a_dead_runners_claim_expires_by_profile_and_only_a_person_reruns_the_uncertain_one
    File.write(File.join(@home, "settings.json"),
      JSON.generate({ "extensions" => ["rho/dev"], "extension_paths" => [] }))
    # AGENT MODE (r-modes M1): the empty prelude loads no runner tool, and a
    # full-mode boot refuses to serve nothing — so this rho registers no
    # runner row and NAMES the process on every turn.
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home,
      env: { "RUBYOPT" => "-r#{EMPTY_PRELUDE}", "RHO_MODE" => "agent" })
    @workspace_public_id = boot_rho
    await_rho_log(/event=executor\.announced tools=0\b/, "the empty announcement never landed")
    @process = grant_and_start_executor(tools: E2E::EchoTools.names)

    a_replayable_claim_times_out_and_nothing_requeues_it
    a_write_claim_settles_uncertain_and_a_persons_retry_reruns_it
  end

  private

    # (a) The model calls `slow_read` for two minutes; the process takes
    # it and dies. Past the deadline the sweep writes `timed_out` — a
    # read is harmless to re-run, and the model reads the envelope on its
    # next round and may re-issue it. The restarted process finds NOTHING
    # to claim for that loop: the kernel put nothing back.
    def a_replayable_claim_times_out_and_nothing_requeues_it
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      arguments = CGI.escape(JSON.generate({ "seconds" => 120 }))
      loop_id = rho_do("!mock tool_call=slow_read tool_args=#{arguments} -- say what happened", project,
        runner: @process.executor_public_id)
      claim = await_claim
      @process.kill!
      expire!(claim)

      completed = await_loop_status(loop_id, "completed")
      tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
      refute_nil tool_task, "the model never called the tool: #{summarize(completed)}"
      assert_equal "slow_read", tool_task.fetch("tool_name")
      assert_equal "timed_out", tool_task.fetch("status"),
        "a replayable profile expires timed_out, never uncertain: #{tool_task.inspect}"
      assert_equal "tool_timeout", tool_task.dig("error", "key"), tool_task.inspect
      assert_equal claim.fetch("task"), tool_task.fetch("key"), "the row the dead process held is the one that expired"

      continuation = task_output(loop_id, "r2")
      assert_includes continuation, "The tool call exceeded its deadline.",
        "the continuation read the paired timeout: #{continuation.inspect}"
      assert_includes continuation, "(tool_timeout)", continuation.inspect

      @process.start
      await("the restarted process never swept twice") { @process.statuses.length >= 2 ? true : nil }
      assert_equal 0, @process.claimed, "nothing was re-queued for the restarted process: #{@process.statuses.last.inspect}"
      assert_empty @process.claims, "a settled row is not listed, let alone granted again"
    end

    # (b) A step a PERSON authored: `slow_write` under `on_failure: halt`.
    # The process takes it and dies; past the deadline the sweep writes
    # `uncertain` — an open-world write nobody answered for — and the loop
    # holds with the row named. The person reads the word and the two
    # verbs off `rho watch`, decides with `rho retry`, and the row runs
    # again under a new generation on the restarted process.
    def a_write_claim_settles_uncertain_and_a_persons_retry_reruns_it
      loop_id = author_slow_write_loop!
      attached, status = @daemon.cli("attach", loop_id)
      assert_predicate status, :success?, "rho attach failed:\n#{attached}"
      claim = await_claim(key: "slow")
      @process.kill!
      expire!(claim)

      held = await_loop_status(loop_id, "needs_attention")
      assert_equal "halt_failure", held.dig("attention", "reason"), held.inspect
      task = held.fetch("tasks").find { |row| row.fetch("key") == "slow" }
      assert_equal "uncertain", task.fetch("status"),
        "a claimed open-world write nobody answered for is uncertain: #{task.inspect}"
      assert_equal "tool_uncertain", task.dig("error", "key"), task.inspect
      assert_includes task.dig("error", "detail").to_s, "may have happened", task.inspect

      watched, status = @daemon.cli("watch", loop_id, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
      assert_predicate status, :success?, "rho watch failed:\n#{watched}"
      assert_match(/^  uncertain\s+slow\s+\(tool_uncertain\)\s+— #{Regexp.escape(UNCERTAIN_HINT)}$/, watched,
        "the task line names the word and the two verbs that decide it:\n#{watched}")
      assert_match(/^  ASKING\s+halt_failure — slow$/, watched, watched)
      assert_match(/^status:\s+failed$/, watched, "a hold reads as a level, not the end:\n#{watched}")

      retried, status = @daemon.cli("retry", loop_id)
      assert_predicate status, :success?, "rho retry failed:\n#{retried}"
      assert_match(/^retried:\s+slow$/, retried, "the sole candidate needs no key:\n#{retried}")

      @process.start
      completed = await_loop_status(loop_id, "completed")
      task = completed.fetch("tasks").find { |row| row.fetch("key") == "slow" }
      assert_equal "completed", task.fetch("status"), "the new generation ran on the restarted process: #{summarize(completed)}"
      output = task_output(loop_id, "slow")
      assert_includes output, "echo:slow_write:", "the process's own handler answered: #{output.inspect}"
      assert_includes output, "\"seconds\":#{SLOW_SECONDS}", "the frozen input was re-run as authored: #{output.inspect}"
      assert_equal ["slow"], @process.claimed_keys, "the restarted process claimed the re-queued row once"
    end

    # ---- the harness: one rho, one grant, one process ----

    LOOP_POLL = 1
    AWAIT_SECONDS = 120

    def boot_rho
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      E2E.enable_dev_lane!
      E2E.hosts.start
      await_workspace_state("adopted").dig("workspace", "public_id")
    end

    # THE GRANT, then the process: the transport credential comes only
    # through the browser ceremony a person completes, one budget consume
    # per grant, and reaches the child on stdin — the restart spends none.
    def grant_and_start_executor(tools:)
      E2E::DeviceAuthorizationBudget.consume
      authorization = @client.request_runner_authorization(
        runner_identifier: RUNNER_IDENTIFIER, runner_display_name: RUNNER_DISPLAY_NAME
      )
      assert_equal :runner, authorization.branch
      E2E::RunnerGrant.visit_connection(actor: @actor, authorization: authorization)
      offer = E2E::RunnerGrant.scope_offer(@actor)
      inherited = offer if %i[account_wide user_private].include?(offer)
      E2E::RunnerGrant.connect_in_browser(actor: @actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
      credentials = @client.await_credentials(authorization)
      assert_nil credentials.access_token, "a runner is a delivery address, never a member principal"

      process = E2E::ExecutorProcess.new(base_url: @base_url, home: @executor_home,
        credential: credentials.executor_access_token, tools: tools)
      process.start
      assert_equal tools.sort, process.announced.sort, "the process announced what it was asked to"
      process
    end

    # The person's own shape, authored over the member plane (no rho verb
    # creates a loop from steps): one open-world write that halts on
    # failure, started at once. The Human half NAMES the process too
    # (r-modes M6): the kernel infers no binding, so an unnamed loop would
    # park nothing for the process — its `slow_write` would fail
    # `tool_not_served` at start.
    def author_slow_write_loop!
      path = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops"
      body, status = agent_api_post(path, { "agent_loop" => {
        "runner_executor_public_id" => @process.executor_public_id,
        "steps" => [
          { "tool" => { "key" => "slow", "name" => "slow_write", "input" => { "seconds" => SLOW_SECONDS },
                        "on_failure" => "halt" } },
        ],
        "approval_mode" => "bypass",
      } })
      assert_equal 201, status, "authoring the slow_write loop: #{body}"
      loop_id = body.dig("agent_loop", "public_id")
      _, started = agent_api_post("#{path}/#{loop_id}/start", {})
      assert_equal 200, started, "starting the slow_write loop"
      loop_id
    end

    # The runner's claim line — the mark between the grant and the answer
    # nobody will give. With a key, the claim for that row; without, the
    # first this process was granted.
    def await_claim(key: nil)
      await("the process never claimed #{key || "a row"}") do
        @process.claims.find { |claim| key.nil? || claim.fetch("task") == key }
      end
    end

    # THE DEADLINE FIRST, THEN THE SWEEP: the sweep leaves a park whose
    # deadline stands (`idle`), so the journey waits for the clock the
    # claim answered, then runs the operator's sweep rather than the
    # scheduler's minute.
    def expire!(claim)
      deadline = Time.iso8601(claim.fetch("deadline_at"))
      await("the park's deadline never passed (#{deadline.iso8601})", every: 1) do
        Time.now > deadline + 1 ? true : nil
      end
      E2E.operator.sweep_park_timeouts!
    end

    # `rho do`, the shipped verb, and the id of the loop backing the turn;
    # `runner` names the runner-kind executor the turn's tools run on.
    def rho_do(prompt, project, runner: nil)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project,
        *(["--runner", runner] if runner))
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      loop_id = output[/^loop:\s+(\S+)/, 1]
      refute_nil loop_id, output
      loop_id
    end

    def await_rho_log(pattern, message)
      @daemon.await(message) { rho_log.match?(pattern) ? true : nil }
    end

    def rho_log
      path = File.join(@home, "log", "rho.log")
      File.file?(path) ? File.read(path, encoding: Encoding::UTF_8) : ""
    end

    def loop_path(loop_id) = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops/#{loop_id}"

    def loop_row(loop_id)
      document = agent_api(loop_path(loop_id))
      document.fetch("agent_loop") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def await_loop_status(loop_id, status)
      await("the loop never reached #{status}", every: LOOP_POLL) do
        row = loop_row(loop_id)
        row if row["status"] == status
      end
    end

    def task_output(loop_id, key) = agent_api("#{loop_path(loop_id)}/tasks/#{key}").dig("task", "output").to_s

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

    def sign_in_steward
      @actor.visit("/session/new")
      @page.fill_in "Email", with: @steward.email
      @page.fill_in "Password", with: @steward.password
      E2E::SessionSignInBudget.consume
      @page.click_button "Sign in"
      assert @page.has_text?("Dashboard")
    end

    def stop_quietly(label)
      yield
    rescue StandardError => error
      warn "Could not stop #{label}: #{error.class}: #{error.message}"
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
