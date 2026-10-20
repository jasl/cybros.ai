require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/runner_grant"
require "support/printed_envelope"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/session_sign_in_budget"
require "support/thread_check"

# THE ACCEPTANCE CHECK AS A RUNNER TOOL STEP. `rho do PROMPT --until COMMAND` on a full-mode rho:
# when the model ends its turn the check is not run in the daemon — it is `check-N`, a `bash` tool
# row the kernel addresses to the host's bound runner (here rho's own), claimed and run there like
# any of the model's calls; its verdict is the row's `exit_status`; the hold behind it (`hold-N`)
# keeps the loop open until rho's gate reads the row and plants the next attempt. The same ladder
# `live_until` climbs on a real model, on the mock: the check fails once, the model is asked to
# continue, the check passes, the summary round answers.
#
# The first input registers its check before the run starts. The model's
# file write exercises expansion of the first round without an artificial
# delay for check registration.
class UntilTest < Minitest::Test
  include E2E::ThreadCheck
  MODEL = "dev/mock-text".freeze
  TROUBLE = /runner_task_failed|runner_submit_refused/

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-until-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      E2E::SecretHygiene.save_screenshot(
        @actor, File.expand_path("../artifacts/screenshots/until-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture until E2E capture: #{error.class}: #{error.message}"
  ensure
    begin
      @daemon&.stop
    rescue StandardError => error
      warn "Could not stop rho: #{error.class}: #{error.message}"
    end
    @offline_run&.stop(force: true) if @offline_run&.fetch&.status == "running"
    @independent&.stop
    @actor&.close
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_the_check_runs_as_a_bash_tool_step_on_rhos_own_runner
    boot_rho
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "check.sh"), <<~SH)
      #!/bin/sh
      # Fails on its first run, passes from the second: a ladder, not a coin.
      n=$(cat .check-count 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > .check-count
      if [ ! -f note.txt ]; then echo "note.txt is missing"; exit 2; fi
      if [ "$n" -lt 2 ]; then echo "not yet: run $n"; exit 1; fi
      echo "ok on run $n"
    SH
    @daemon.control(:post, "/environment", body: { root: project })

    # The model's one call writes the file the check wants.
    call = CGI.escape(JSON.generate({ "command" => "printf hello > note.txt" }))
    output, status = @daemon.cli("do", "!mock tool_call=bash tool_args=#{call} -- done",
      "--model", MODEL, "--dir", project, "--until", "sh check.sh", "--attempts", "3")
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    assert_match(/^until:\s+sh check\.sh \(3 checks, on runner #{@rho_runner} in #{Regexp.escape(project)}\)$/, output,
      "this machine's own runner: the directory, no runner named:\n#{output}")
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, output

    watched, status = @daemon.cli("watch", loop_id, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, watched
    done = loop_row(loop_id)
    assert_equal "completed", done.fetch("status"), summarize(done)

    # THE THREAD: the ladder's model steps are mainline rows; its checks are tool rows with no `r<n>t`
    # key — calls of no round — and its holds are hidden; nothing branches.
    thread = assert_thread_matches_graph!(loop_id)
    mainline = thread.fetch("mainline")
    assert_includes mainline.map { |row| row["key"] }, "summary", "the ladder's last round is on the mainline: #{thread.inspect}"
    assert_includes mainline.map { |row| row["key"] }, "work-2"
    refute_includes mainline.flat_map { |row| row["calls"] }, "check-1", "an --until check is a call of no round"
    refute_includes mainline.flat_map { |row| row["calls"] }, "check-2"
    assert_empty thread.fetch("branches")

    # THE LADDER, IN THE TRACE: the kernel's first round with the check and
    # its hold hung below it, the second attempt with its own, the summary.
    keys = done.fetch("tasks").to_h { |t| [t.fetch("key"), t] }
    %w[r1 check-1 hold-1 work-2 check-2 hold-2 summary].each do |key|
      assert keys.key?(key), "expected #{key} in the trace: #{keys.keys.inspect}"
    end
    refute keys.key?("work-3"), "the second check passed; nothing more was planted"

    # THE NEXT ROUND READS THE CHECK BY NAME: nothing crosses an append by position, so each round
    # the gate plants names its attempt's check — the output — and its hold — the verdict line.
    nodes = agent_api("#{loop_path(loop_id)}/graph").fetch("nodes").to_h { |node| [node.fetch("key"), node] }
    assert_equal %w[check-1 hold-1], nodes.fetch("work-2").fetch("result_from"), nodes.fetch("work-2").inspect
    assert_equal %w[check-2 hold-2], nodes.fetch("summary").fetch("result_from"), nodes.fetch("summary").inspect

    # THE CHECK IS A TOOL ROW ON THE RUNNER: bash, addressed to rho's own
    # runner address through the kernel's one site, claimed by it, and
    # its verdict on the row's structured content.
    %w[check-1 check-2].each do |key|
      check = keys.fetch(key)
      assert_equal %w[tool_task bash completed], check.values_at("kind", "tool_name", "status"), check.inspect
      assert_equal({ "role" => "runner", "executor_public_id" => @rho_runner, "presence" => "online" },
        check.fetch("addressed_to").except("last_seen_at"), "#{key} was addressed elsewhere: #{check.inspect}")
      assert_equal({ "executor_public_id" => @rho_runner }, check.fetch("claimed_by"), check.inspect)
      assert_equal "await_task", keys.fetch(key.sub("check", "hold")).fetch("kind")
      assert_equal "completed", keys.fetch(key.sub("check", "hold")).fetch("status"),
        "the hold is resolved inside the append that plants the next step"
    end
    first = task_detail(loop_id, "check-1")
    assert_equal 1, first.dig("structured_content", "exit_status"), first.inspect
    assert_includes first.fetch("output").to_s, "not yet: run 1", "the row's result is the evidence: #{first.inspect}"
    second = task_detail(loop_id, "check-2")
    assert_equal 0, second.dig("structured_content", "exit_status"), second.inspect
    assert_includes second.fetch("output").to_s, "ok on run 2"

    # WHOSE LOG SAYS SO: rho's own runner claimed both checks as bash.
    claims = @daemon.claims.select { |claim| %w[check-1 check-2].include?(claim["task"]) }
    assert_equal %w[check-1 check-2], claims.map { |claim| claim["task"] }, @daemon.claims.inspect
    assert_equal %w[bash bash], claims.map { |claim| claim["tool"] }, claims.inspect
    refute_match(/until\.too_late/, @daemon.log_text, "the check was hung on a loop that had already settled")
    refute_match TROUBLE, @daemon.log_text, "rho's runner met a refusal or a failure"

    # THE PERSON SAW EACH VERDICT LAND, and the answer is the summary.
    assert_match(/^  check 1\/3: exit 1$/, watched, watched)
    assert_match(/^  check 2\/3: passed$/, watched, watched)
    result, status = @daemon.cli("result", loop_id)
    assert_predicate status, :success?, result
    refute_empty result.strip, "the summary round is the loop's answer"
    assert_equal "hello", File.read(File.join(project, "note.txt"), encoding: Encoding::UTF_8).strip
    assert_operator Integer(File.read(File.join(project, ".check-count")).strip), :>=, 2,
      "the check ran at least twice, on the runner"
  end

  def test_until_recovers_an_archived_goal_without_a_follower_cache_or_a_bound_run_marker
    boot_rho
    project = File.join(@home, "offline-project").tap { |path| FileUtils.mkdir_p(path) }
    runner_home = File.join(@home, "offline-runner").tap { |path| FileUtils.mkdir_p(path) }
    device = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    E2E::DeviceAuthorizationBudget.consume
    authorization = device.request_runner_authorization(registration_identifier: "e2e-until-#{SecureRandom.hex(4)}",
      runner_display_name: "Independent until environment")
    E2E::RunnerGrant.visit_connection(actor: @actor, authorization: authorization)
    E2E::RunnerGrant.connect_in_browser(actor: @actor, authorization: authorization)
    credentials = device.await_credentials(authorization)
    @independent = E2E::ExecutorProcess.new(base_url: @base_url, home: runner_home,
      credential: credentials.executor_access_token, world: project, environment: project).start
    if ENV["E2E_RECOVERY_SCALE"]
      require "support/recovery_scale"
      report = File.join(Dir.tmpdir, "rho-recovery-scale-#{Process.pid}.json")
      E2E::RecoveryScale.seed(handle: E2E.handle, size: Integer(ENV.fetch("E2E_RECOVERY_SCALE")),
        workspace: @workspace_public_id, agent: @daemon.status.fetch("identity").fetch("user_public_id"), report: report)
      puts "recovery query plans: #{report}"
    end
    command = 'n=$(cat .checks 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > .checks; if [ "$n" = 1 ]; then sleep 10; printf requires-another-attempt; exit 1; fi; printf passed'
    output, status = @daemon.cli("do", "!mock reply=first-attempt -- start the work", "--model", MODEL,
      "--runner", @independent.executor_public_id, "--dir", project,
      "--until", command, "--attempts", "3")
    assert_predicate status, :success?, output
    run_id = output[/^run:\s+(\S+)/, 1]
    refute_nil run_id, output
    @offline_run = @daemon.member_client.workspace(@workspace_public_id).run(run_id)
    @daemon.await("the independent Runner never claimed the check") { @independent.claimed_keys.include?("check-1") }
    cache = @daemon.host_cache_path
    @daemon.kill!
    @daemon.await("the independent check never finished after rho exited") do
      tasks = @offline_run.fetch.tasks
      tasks.find { |task| task.key == "check-1" && task.status == "completed" } &&
        tasks.find { |task| task.key == "hold-1" && task.status == "dispatched" }
    end
    check = @offline_run.task("check-1")
    assert_equal @independent.executor_public_id, check.task.claimed_by.executor_public_id
    assert_equal 1, check.structured_content.fetch("exit_status")
    assert_includes check.output, "requires-another-attempt"
    2.times do
      row = @offline_run.fetch
      assert_equal "running", row.status
      assert_equal "dispatched", row.tasks.find { |task| task.key == "hold-1" }.status
      refute row.tasks.any? { |task| %w[work-2 check-2 summary].include?(task.key) },
        "Nexus persists the check and hold; Rho owns authoring another attempt"
      sleep 1
    end
    # Reproduce the acceptance/binding crash window using durable policy.
    conversation = @offline_run.fetch.turn.conversation_public_id
    chat = @daemon.member_client.workspace(@workspace_public_id).conversation(conversation)
    summary = chat.store_entries.list.items.find { |row| row.namespace == "rho.host" && row.key == "policy" }
    entry = chat.store_entries.fetch(summary.public_id)
    notes = entry.value.fetch("notes")
    value = entry.value.merge("notes" => notes.merge("rho.until" => notes.fetch("rho.until").merge("run_public_id" => nil)))
    chat.store_entries.update(entry.public_id, value: value, lock_version: entry.lock_version)
    chat.archive
    FileUtils.rm_f(cache)
    FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
    resumed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @daemon.start
    await_workspace_state("adopted")
    @daemon.await("durable Until recovery did not finish the archived goal", timeout: ENV["E2E_RECOVERY_SCALE"] ? 180 : 60) do
      @offline_run.fetch.status == "completed"
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - resumed_at
    keys = @offline_run.fetch.tasks.map(&:key)
    assert_equal 1, keys.count("work-2"), keys.inspect
    assert_includes keys, "summary"
    assert_equal "2", File.read(File.join(project, ".checks")).strip, "the completed check was not replayed"
    assert_empty @daemon.control(:get, "/followers").fetch("followers"), "recovery does not adopt a follower"
    assert_operator elapsed, :<, Rho::Until::HOLD_TIMEOUT_MS / 1000.0
    puts format("until recovery without cache: %.3f seconds", elapsed)
    puts File.readlines(@daemon.rho_log_path).grep(/until.scan_completed/).last if ENV["E2E_RECOVERY_SCALE"]
  end

  def test_a_cold_runner_uses_each_accepted_directory_and_fails_if_it_disappears
    boot_rho
    default = File.join(@home, "default").tap { |path| FileUtils.mkdir_p(path) }
    selected = File.join(@home, "selected").tap { |path| FileUtils.mkdir_p(path) }
    @daemon.control(:post, "/environment", body: { root: default })
    workspace = @daemon.member_client.workspace(@workspace_public_id)
    steps = [CybrosAgent::Steps::Tool.new(name: "write", key: "write",
      input: { "path" => "proof.txt", "content" => "selected" },
      route: { "kind" => "runner", "runner_executor_public_id" => @rho_runner },
      executor_context: { "rho.environment" => { "root" => selected, "directories" => [] } })]
    accepted = workspace.runs.create(steps: steps, approval_mode: "bypass", idempotency_key: SecureRandom.uuid,
      default_runner_executor_public_id: @rho_runner)
    context = workspace.run(accepted.run.public_id)
    @daemon.kill!
    FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
    @daemon.start
    await_workspace_state("adopted")
    await_rho_announced
    context.start
    @daemon.await("the cold Runner did not complete the accepted write") { context.fetch.status == "completed" }
    assert_equal "selected", File.read(File.join(selected, "proof.txt"))
    refute_path_exists File.join(default, "proof.txt")
    assert_equal selected, context.task("write").executor_context.dig("rho.environment", "root")

    FileUtils.remove_entry(selected)
    missing = workspace.runs.create(steps: steps, approval_mode: "bypass", idempotency_key: SecureRandom.uuid,
      default_runner_executor_public_id: @rho_runner)
    failed = workspace.run(missing.run.public_id)
    failed.start
    task = @daemon.await("the vanished directory did not fail its task") do
      row = failed.task("write")
      row if row.task.status == "failed"
    end
    assert_includes task.output, selected
    refute_path_exists File.join(default, "proof.txt")
  end

  # THE SPLIT-APPEND CONTRACT: nothing carries across appends by position, so a summary appended on
  # its own names the four rows it reads by key — and reads exactly what the same summary written in
  # the first envelope reads.
  def test_a_later_append_reads_the_rows_it_names_exactly_as_one_envelope
    boot_rho
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })
    workspace = @daemon.member_client.workspace(@workspace_public_id)
    prefix = [
      { "tool" => { "key" => "diff", "name" => "bash", "executor_context" => { "rho.environment" => { "root" => project } }, "route" => { "kind" => "runner", "runner_executor_public_id" => @rho_runner }, "input" => { "command" => "printf shared-patch-output" } } },
      { "parallel" => [
        { "model" => { "key" => "review", "model" => { "model" => MODEL }, "results" => ["diff"],
                      "prompt" => "!mock reply=review-output -- Review the patch." } },
        { "tool" => { "key" => "check", "name" => "bash", "executor_context" => { "rho.environment" => { "root" => project } }, "route" => { "kind" => "runner", "runner_executor_public_id" => @rho_runner }, "input" => { "command" => "printf check-output" } } },
      ] },
      { "tool" => { "key" => "checkpoint", "name" => "bash", "executor_context" => { "rho.environment" => { "root" => project } }, "route" => { "kind" => "runner", "runner_executor_public_id" => @rho_runner }, "input" => { "command" => "printf checkpoint-output" } } },
    ]
    summary = { "model" => { "key" => "summary", "model" => { "model" => MODEL },
                            "results" => %w[diff review check checkpoint],
                            "prompt" => "!mock reply=summary-output -- Summarize the patch, review and checks." } }

    # Both graphs are authored before dispatch. This tests separate public
    # requests without racing the loop's ordinary completion boundary.
    requests = [false, true].map do |split|
      created = workspace.runs.create(
        steps: split ? prefix : prefix + [summary], approval_mode: "bypass",
        default_runner_executor_public_id: @rho_runner, idempotency_key: SecureRandom.uuid
      )
      context = workspace.run(created.run.public_id)
      context.append(steps: [summary], idempotency_key: SecureRandom.uuid) if split
      context.start
      completed = @daemon.await("the #{split ? "split" : "single"} envelope never completed") do
        row = context.fetch
        flunk "the workflow cannot complete: #{row.to_h.inspect}" if %w[failed needs_attention].include?(row.status)
        row if row.status == "completed"
      end
      assert_equal "summary", completed.deliverable_task_key
      assert completed.tasks.all? { |task| task.status == "completed" }, completed.tasks.map(&:to_h).inspect
      context.tasks_context("summary").request.entries
    end

    assert_equal requests.first, requests.last,
      "splitting the authoring requests must preserve the summary's sealed model input"
    texts = requests.last.flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }
    { "diff" => "shared-patch-output", "check" => "check-output", "checkpoint" => "checkpoint-output" }.each do |key, output|
      assert_includes texts, E2E::PrintedEnvelope.of(key, output),
        "the summary must receive #{key}'s result separately from the review's interpretation, its body after its call"
    end
    assert texts.any? { |text| text.include?("review-output") }, "the summary must also receive the review's answer"
  end

  private

    # One full-mode rho: paired on the combined page, adopting a workspace,
    # registering its own runner row and announcing its tools.
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

    def await_rho_announced
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
    end

    def loop_path(loop_id) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop_id}"

    def loop_row(loop_id)
      document = agent_api(loop_path(loop_id))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_detail(loop_id, key) = agent_api("#{loop_path(loop_id)}/tasks/#{key}").fetch("task")

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

    def sign_in_steward
      @actor.visit("/session/new")
      @page.fill_in "Email", with: @steward.email
      @page.fill_in "Password", with: @steward.password
      E2E::SessionSignInBudget.consume
      @page.click_button "Sign in"
      assert @page.has_text?("Overview")
    end

    LOG_TAIL_LINES = 120

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
