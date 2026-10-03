require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
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
# WHY THE FIRST ROUND SLEEPS: the check is hung below `r1` after the turn
# materializes; a mock round with no call completes in under a second
# and the append would land on a settled loop (`until.too_late`, the
# tolerated arm). A three-second bash keeps `r1` live for the append, and
# the journey asserts the race did not happen.
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

    # The model's one call writes the file the check wants and holds `r1`
    # open for the check to be hung below it.
    call = CGI.escape(JSON.generate({ "command" => "sleep 3; printf hello > note.txt" }))
    output, status = @daemon.cli("do", "!mock tool_call=bash tool_args=#{call} -- done",
      "--model", MODEL, "--dir", project, "--until", "sh check.sh", "--attempts", "3")
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    assert_match(/^until:\s+sh check\.sh \(3 checks, in #{Regexp.escape(project)}\)$/, output,
      "this machine's own runner: the directory, no runner named:\n#{output}")
    loop_id = output[/^loop:\s+(\S+)/, 1]
    refute_nil loop_id, output

    watched, status = @daemon.cli("watch", loop_id, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, watched
    done = loop_row(loop_id)
    assert_equal "completed", done.fetch("status"), summarize(done)

    # THE THREAD: the ladder's model steps are spine rows; its checks are tool rows with no `r<n>t`
    # key — calls of no round — and its holds are hidden; nothing branches.
    thread = assert_thread_matches_graph!(loop_id)
    spine = thread.fetch("spine")
    assert_includes spine.map { |row| row["key"] }, "summary", "the ladder's last round is on the spine: #{thread.inspect}"
    assert_includes spine.map { |row| row["key"] }, "work-2"
    refute_includes spine.flat_map { |row| row["calls"] }, "check-1", "an --until check is a call of no round"
    refute_includes spine.flat_map { |row| row["calls"] }, "check-2"
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

  # THE SPLIT-APPEND CONTRACT: nothing carries across appends by position, so a summary appended on
  # its own names the four rows it reads by key — and reads exactly what the same summary written in
  # the first envelope reads.
  def test_a_later_append_reads_the_rows_it_names_exactly_as_one_envelope
    boot_rho
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })
    api = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    workspace = api.workspace(@workspace_public_id)
    prefix = [
      { "tool" => { "key" => "diff", "name" => "bash", "input" => { "command" => "printf shared-patch-output" } } },
      { "parallel" => [
        { "model" => { "key" => "review", "model" => { "model" => MODEL }, "results" => ["diff"],
                      "prompt" => "!mock reply=review-output -- Review the patch." } },
        { "tool" => { "key" => "check", "name" => "bash", "input" => { "command" => "printf check-output" } } },
      ] },
      { "tool" => { "key" => "checkpoint", "name" => "bash", "input" => { "command" => "printf checkpoint-output" } } },
    ]
    summary = { "model" => { "key" => "summary", "model" => { "model" => MODEL },
                            "results" => %w[diff review check checkpoint],
                            "prompt" => "!mock reply=summary-output -- Summarize the patch, review and checks." } }

    # Both graphs are authored before dispatch. This tests separate public
    # requests without racing the loop's ordinary completion boundary.
    requests = [false, true].map do |split|
      created = workspace.agent_loops.create(
        steps: split ? prefix : prefix + [summary], approval_mode: "bypass",
        runner_executor_public_id: @rho_runner, idempotency_key: SecureRandom.uuid
      )
      context = workspace.agent_loop(created.agent_loop.public_id)
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

    def loop_path(loop_id) = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops/#{loop_id}"

    def loop_row(loop_id)
      document = agent_api(loop_path(loop_id))
      document.fetch("agent_loop") { flunk "the loop read was refused: #{document.inspect}" }
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
      assert @page.has_text?("Dashboard")
    end

    LOG_TAIL_LINES = 120

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
