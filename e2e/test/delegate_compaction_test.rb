require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/compaction_results"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/session_sign_in_budget"
require "support/thread_check"

# THE DELEGATED COMPACTION, END TO END: the kernel compacts by default, and an agent that declares
# its own receives each compaction as an inbox row addressed to its own address — a `tool_call`
# naming the policy's `tool_name`, carrying the history rendered as pointers — and answers it with
# the summary. Under `compaction: {mode: delegate}` in rho's settings the declaration names
# `summarize_history`, the shipped extension's own tool: rho claims the row, places ONE InferenceRequest on
# its model through the member plane under its own prompt, and commits the text; the round composes
# from it exactly as it would from the kernel's summarizer.
#
# (a) THE SHAPE, on the mock: `k1` is a `tool_task` `summarize_history`
#     `completed` on the trace, ONE `context_compacted{mode: delegate}`,
#     the workspace holds rho's one InferenceRequest, and `k1`'s text is the mock's
#     ECHO of rho's prompt plus the pointer rendering — nobody scripts
#     rho's own InferenceRequest, so the CONTENT of a real summary is the paid
#     `live_long_session` run's, never this one's.
# (b) THE FALLBACK (decision 9): a second rho, its handler parked by a
#     prelude so the claim stands unanswered, is KILLED holding `k1`; the
#     operator backdates the park and runs the sweep; `k1` settles
#     `timed_out` by its replayable profile, the kernel appends its own
#     summarizer `k2` ONCE — narrated `context_compacted{mode: kernel,
#     trigger: fallback, fallback_from: k1, fallback_reason: tool_timeout}`
#     — and the loop completes with rho dead: round 2 speaks on the mock
#     and the turn converges kernel-side.
#
# Two rhos in sequence on one steward (one live address per profile), two
# grants; the second rho boots after the first stopped.
class DelegateCompactionTest < Minitest::Test
  include E2E::ThreadCheck
  include E2E::CompactionResults
  MODEL = "dev/mock-text".freeze
  DELEGATE_HOLD_PRELUDE = File.expand_path("../support/delegate_hold_prelude.rb", __dir__)
  # THE SUMMARIZER SLOT UNDER DELEGATE: the home pins a local row that CARRIES a
  # `summarizer_prompt`, and under `delegate` rho deletes the slot instead of writing it (write only
  # what is read) — so the kernel's fallback summarizer `k2` seals the kernel's own default text,
  # never the row's. Over the DEV SET: the home writes its own file, so it names `rho/dev` itself.
  SETTINGS = E2E::RhoDaemon.dev_settings(
    plugins: { "rho.compaction" => { "configuration" => { "mode" => "delegate", "model" => MODEL } } }, adaptations: "mock-summary"
  ).freeze
  ROW_SUMMARIZER = "Compact this transcript for the mock: name every file and result as a pointer, never its " \
    "value, and end on the next action.".freeze
  MOCK_SUMMARY_ROW = <<~YAML.freeze
    format: 1
    row: mock-summary
    models: []
    tool_style: [nexus]
    summarizer_prompt: "#{ROW_SUMMARIZER}"
  YAML
  KERNEL_SUMMARIZER_OPENING = "You are compacting the transcript of a conversation so it can\ncontinue in a " \
    "smaller context.".freeze
  # The kernel's own words a compaction leaves in a request (the twins in
  # rho_conversation_test): the frame before every summary a model reads,
  # and the kernel summarizer's rendering.
  REREAD_RULE = "This summary replaces earlier history and carries no data values: " \
    "re-read any file, output or result it mentions before you use it.".freeze
  COMPACTION_HEADER = "Here is the transcript to compact.".freeze
  # RHO'S OWN PROMPT, by its first sentence — the extension pins the whole
  # text; the journey reads that the InferenceRequest carried it.
  RHO_PROMPT_OPENING = "You are summarizing the earlier part of a coding agent's conversation".freeze
  DELEGATE = "summarize_history".freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-delegate-e2e")
    @held_home = Dir.mktmpdir("rho-delegate-held-e2e")
    @daemon = nil
    @held = nil
    sign_in_steward
  end

  def teardown
    unless passed?
      [@daemon, @held].compact.each do |daemon|
        warn_log(daemon.log_path, "rho daemon stdout (#{daemon.home})")
        warn_log(daemon.rho_log_path, "rho structured log (#{daemon.home})")
      end
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/delegate_compaction-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture delegate compaction E2E capture: #{error.class}: #{error.message}"
  ensure
    [@held, @daemon].compact.each do |daemon|
      if (result = daemon.dispose_connection)
        output, status = result
        assert_predicate status, :success?, output
      end
    end
    @actor&.close
    [@home, @held_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_a_delegated_compaction_is_answered_by_rho_and_falls_to_the_kernel_once_when_rho_dies
    the_agents_own_summarizer_answers_the_delegate_row
    a_delegate_nobody_answered_expires_and_the_kernel_summarizes_once
  end

  private

    # (a) The usage arm fires on round 2 (`rho_conversation_test`'s
    # trigger: round 1 reports 9 000 tokens against the dev model's 8 192
    # window); under the delegate policy the arm's row is `k1`, addressed
    # to rho, and rho's handler answers it through one InferenceRequest.
    def the_agents_own_summarizer_answers_the_delegate_row
      @daemon = boot_rho(E2E::RhoDaemon.new(base_url: @base_url, home: @home), @home)
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      marker = "first-line-#{SecureRandom.hex(6)}"
      prompt = compaction_prompt(project, marker)
      conversation, turn, loop = open_turn(@daemon, prompt, project)

      completed = await_run_status(loop, "completed")
      variant_id = loop_variant(conversation, turn, loop)
      tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
      assert_equal %w[completed completed], [tasks.fetch("r1").fetch("status"), tasks.fetch("r2").fetch("status")],
        "the round and its continuation both settled: #{summarize(completed)}"
      delegate = tasks.fetch("k1") { flunk "no delegate on the trace: #{summarize(completed)}" }
      assert_equal %w[tool_task summarize_history completed collapsed],
        [delegate.fetch("kind"), delegate.fetch("tool_name"), delegate.fetch("status"), delegate.fetch("visibility")],
        "the arm's row is the agent's own tool, answered: #{delegate.inspect}"
      claim = @daemon.claims.find { |line| line["task"] == "k1" }
      refute_nil claim, "rho's runner claimed the delegate row: #{@daemon.claims.inspect}"
      # THE AGENT ADDRESS SERVED IT (r-modes): the delegate is the agent's own
      # tool, claimed by the agent address's loop — never the runner's.
      assert_equal "agent", claim["address"], "the claim line names the address that served it: #{claim.inspect}"

      compactions = feed(conversation).select { |item| item["type"] == "context_compacted" }
      assert_equal 1, compactions.size, "exactly one repair on one wall: #{compactions.map { |c| c["payload"] }.inspect}"
      assert_equal({ "mode" => "delegate", "trigger" => "usage", "task_key" => "r2", "summary_task_key" => "k1",
                     "variant_public_id" => variant_id,
                     "run_public_id" => loop, "turn_public_id" => turn }, compactions.first.fetch("payload"))

      # THE ECHO OF RHO'S OWN ONESHOT: the mock speaks its input back, so
      # the delegate's answer reads as rho's prompt followed by the
      # kernel's pointer rendering — and never the result's value.
      summary = task_output(loop, "k1")
      assert summary.start_with?("Mock:"), "the delegate's answer is the mock's echo of rho's InferenceRequest: #{summary[0, 120].inspect}"
      assert_includes summary, RHO_PROMPT_OPENING, "rho's own prompt led the InferenceRequest"
      assert_includes summary, "Tool bash (completed, ok)", "the kernel's pointer rendering rode in `history`"
      assert_includes summary, "not carried"
      refute_includes summary, marker, "a summary carries pointers, never the result's value"
      refute_includes summary, COMPACTION_HEADER, "the kernel's own summarizer did not run"

      inference_requests = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/inference_requests").fetch("inference_requests")
      assert_equal [%w[text_generation completed]], inference_requests.map { |row| [row.fetch("workload"), row.fetch("status")] },
        "rho placed exactly one InferenceRequest for the summary: #{inference_requests.inspect}"

      continued = task_output(loop, "r2")
      assert_includes continued, REREAD_RULE, "the kernel's frame leads the repaired round's request"
      assert_includes continued, RHO_PROMPT_OPENING, "round 2 composed from the delegate's row, in place of the history"
      assert_equal 1, continued.scan(marker).length, "the new result is consumed exactly once after the summary"
      assert_compaction_result_request(loop, marker)

      # THE THREAD: rho's summarizer `k1` is a tool row hung under the round with no maker — a call
      # of no round, on no page — and the repaired round carries the cut.
      thread = assert_thread_matches_graph!(loop)
      refute_includes thread.fetch("mainline").flat_map { |row| row["calls"] }, "k1", "a summarizer is not a call the round made"
      assert_empty thread.fetch("branches")
      repaired = agent_api("#{loop_path(loop)}/transcript").fetch("rounds").find { |row| row["task_key"] == "r2" }
      assert_equal "r2", repaired.fetch("compacted_before"), "the reader draws the cut from the round that read the summary"

      @daemon.stop
    end

    # (b) The same turn on a rho whose summarizer never answers: it claims
    # `k1` and dies holding it. The operator backdates the park and sweeps;
    # the kernel's fallback appends `k2` once and the loop completes with
    # nobody serving rho's address.
    def a_delegate_nobody_answered_expires_and_the_kernel_summarizes_once
      @held = boot_rho(E2E::RhoDaemon.new(base_url: @base_url, home: @held_home,
        env: { "RUBYOPT" => "-r#{DELEGATE_HOLD_PRELUDE}" }), @held_home)
      project = File.join(@held_home, "project")
      FileUtils.mkdir_p(project)
      marker = "first-line-#{SecureRandom.hex(6)}"
      prompt = compaction_prompt(project, marker)
      conversation, turn, loop = open_turn(@held, prompt, project)

      claim = await("the held rho never claimed the delegate") do
        @held.claims.find { |line| line["task"] == "k1" }
      end
      assert_equal DELEGATE, claim.fetch("tool"), claim.inspect
      @held.kill!
      E2E.operator.expire_park!(loop, "k1")
      E2E.operator.sweep_park_timeouts!

      completed = await_run_status(loop, "completed")
      variant_id = loop_variant(conversation, turn, loop)
      tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
      delegate = tasks.fetch("k1") { flunk "no delegate on the trace: #{summarize(completed)}" }
      assert_equal %w[tool_task timed_out tool_timeout],
        [delegate.fetch("kind"), delegate.fetch("status"), delegate.dig("error", "key")],
        "a replayable delegate nobody answered expires timed_out, never uncertain: #{delegate.inspect}"
      fallback = tasks.fetch("k2") { flunk "the kernel appended no summarizer of its own: #{summarize(completed)}" }
      assert_equal %w[model_task completed collapsed],
        [fallback.fetch("kind"), fallback.fetch("status"), fallback.fetch("visibility")], fallback.inspect
      assert_nil tasks["k3"], "the fallback runs once: #{summarize(completed)}"

      compactions = feed(conversation).select { |item| item["type"] == "context_compacted" }
      assert_equal 2, compactions.size, "the delegate, then the kernel in its place: #{compactions.map { |c| c["payload"] }.inspect}"
      assert_equal({ "mode" => "delegate", "trigger" => "usage", "task_key" => "r2", "summary_task_key" => "k1",
                     "variant_public_id" => variant_id,
                     "run_public_id" => loop, "turn_public_id" => turn }, compactions.first.fetch("payload"))
      assert_equal({ "mode" => "kernel", "trigger" => "fallback", "task_key" => "r2", "summary_task_key" => "k2",
                     "fallback_from" => "k1", "fallback_reason" => "tool_timeout",
                     "variant_public_id" => variant_id,
                     "run_public_id" => loop, "turn_public_id" => turn }, compactions.last.fetch("payload"))

      assert_empty task_output(loop, "k1"), "an expired delegate answered nothing"
      summary = task_output(loop, "k2")
      assert_includes summary, COMPACTION_HEADER, "the kernel's own summarizer read its rendering"
      assert_includes summary, "Tool bash (completed, ok)", "and the call, as a pointer"
      refute_includes summary, marker, "a summary carries pointers, never the result's value"
      refute_includes summary, RHO_PROMPT_OPENING, "the kernel's summarizer, not rho's prompt"
      sealed = agent_api("#{loop_path(loop)}/tasks/k2/request").fetch("request")
      instructions = sealed.dig("request_options", "instructions").to_s
      assert instructions.start_with?(KERNEL_SUMMARIZER_OPENING),
        "the slot is absent under delegate: the fallback sealed the kernel's default text: #{instructions[0, 120].inspect}"
      refute_includes instructions, ROW_SUMMARIZER, "the pinned row's text was never written"
      declared = @held.log_lines.find { |line| line["event"] == "profile.declared" }
      assert_equal %w[delegate deleted], declared&.values_at("compaction", "summarizer"),
        "rho deleted the slot beside the delegate declaration: #{declared.inspect}"

      continued = task_output(loop, "r2")
      assert_includes continued, REREAD_RULE, "the kernel's frame leads the repaired round's request"
      assert_includes continued, COMPACTION_HEADER, "round 2 composed from k2, the kernel's summary"
      refute_includes continued, RHO_PROMPT_OPENING, "and not from k1, which has no text"
      assert_equal 1, continued.scan(marker).length, "the new result is consumed exactly once after the summary"
      assert_compaction_result_request(loop, marker)
    end

    # ---- the harness: one rho at a time, one grant each ----

    # The settings file BEFORE the daemon starts: the delegate flag with
    # the model rho's InferenceRequest runs on (required under `delegate`).
    def boot_rho(daemon, home)
      FileUtils.mkdir_p(File.join(home, "adaptations"))
      File.write(File.join(home, "adaptations", "mock-summary.yml"), MOCK_SUMMARY_ROW)
      File.write(File.join(home, "settings.json"), JSON.generate(SETTINGS), perm: 0o600)
      daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @workspace_public_id = await_workspace_state(daemon, "adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      daemon
    end

    def open_turn(daemon, prompt, project)
      output, status = daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    LOOP_POLL = 1
    AWAIT_SECONDS = 120

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_output(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").dig("task", "output").to_s

    def loop_variant(conversation, turn, loop)
      path = "/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/turns/#{turn}/variants"
      agent_api(path).fetch("variants").find { |variant| variant["run_public_id"] == loop }.fetch("public_id")
    end

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def await_run_status(loop, status)
      await("the loop never reached #{status}", every: LOOP_POLL) do
        row = loop_row(loop)
        row if row["status"] == status
      end
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

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def await_workspace_state(daemon, state)
      daemon.await("the daemon never reported workspace #{state}") do
        document = daemon.status
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

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
