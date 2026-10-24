require "test_helper"
require "support/live_journey"
require "support/live_turns"
require "fileutils"
require "json"
require "tmpdir"

# A REAL MODEL READS A PUBLIC PAGE through `web_fetch`, announced by rho-web-tools beside rho's own tools,
# and proves it by what the FETCH carried — the page's own sentence in the call's output — and by an
# answer on disk; what the model wrote is recorded on the report line, never gated.
#
# THE TASK NAMES THE PAGE AND THE GOAL, NEVER THE TOOL (the MCP lane's
# form): "use web_fetch" would turn REACH into instruction-following. A
# model that ran `curl` through `bash` under `bypass` has answered the task
# and NOT reached the tool — that is the finding, this lane is red for it,
# and red is what it exists to measure: a floor model's reach for the
# described tool ("instead of curl or wget in bash") when a command would
# do. Nothing else in the tree asks that question; the mock journey
# (`web_fetch`) proves the plumbing and never a model.
#
# THE PAGE is IANA's reserved documentation host, `https://example.com/`:
# ~1.2 KB, one paragraph, public, stable, and the private network is NOT
# allowed on this home — the real client, the real SSRF filter, a real
# TLS handshake, the real render, byte for byte what the model reads.
# Stable, not frozen: IANA rewrote the paragraph in 2025 ("illustrative
# examples in documents" became the sentence below), and the smoke's red
# was the model copying the NEW page exactly against the old words — the
# model's wording is the wrong thing to gate; the fetch's output is the
# flow.
#
# WHAT THIS PROVES that the unit suites and the mock journey cannot: the
# extension loads under the daemon from settings.json against a REAL public
# host, the declaration reaches a real provider beside the coding seven,
# and a flash-tier model can choose it at all.
#
# Paid, local, opt-in: E2E_LIVE=1. ONE loop of 2–3 rounds on the floor, ≈ $0.01–0.05; the cost stop
# rides `E2E_LIVE_COST_STOP_USD` (`LiveJourney::COST_STOP_ENV`, else the bench's default row),
# polled under `await_loop_completion`. Run once before the sweep; the sweep glob carries it after
# (`rake live_sweep`), where the description is benched on the second model.
class LiveWebFetchTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  PAGE = "https://example.com/".freeze
  # The page's own sentence (IANA's 2025 text), pinned on the FETCH's
  # output: the page came through the tool, rendered. On the report line
  # it is the task's pass — whether the model copied it.
  EVIDENCE = "This domain is for use in documentation examples without needing permission.".freeze

  include E2E::LiveJourney
  include E2E::LiveTurns

  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-web-e2e")
    @project = Dir.mktmpdir("rho-live-web-project")
    # THE EXTENSION IS WANTED, NOT MERELY INSTALLED, and the private network
    # stays refused: the page is public.
    write_daemon_home!(settings: E2E::RhoDaemon.dev_settings(plugins: { "rho.web_tools" => { "enabled" => true } }))
  end

  def teardown
    finish_live_journey!
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_a_real_model_reads_a_public_page_through_web_fetch
    connect_and_open_lane!

    # THE DAEMON SAYS WHAT IT LOADED, before a model is asked anything: a
    # failed extension is a product fact and reads here.
    listed, status = @daemon.cli("runner")
    assert_predicate status, :success?, "rho runner failed:\n#{listed}"
    assert_match(/^extension:\s+rho\.web_tools \(web_fetch\)$/, listed, "the web extension did not load:\n#{listed}")
    refute_match(/FAILED:/, listed, "an extension failed to load:\n#{listed}")

    @daemon.control(:post, "/environment", body: { root: @project })

    task = <<~TEXT.strip
      Read #{PAGE} and write the exact sentence on that page that says what
      the domain is for into answer.txt, then reply DONE.
    TEXT

    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", @project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    run_public_id = output[/^run:\s+(\S+)/, 1]

    completed = await_loop_completion(run_public_id)
    reached = completed_non_error_calls(completed, "web_fetch")
    fetched = reached.map { |t| task_output(run_public_id, t.fetch("key")) }
    answer_path = File.join(@project, "answer.txt")
    answer = File.read(answer_path, encoding: Encoding::UTF_8) if File.file?(answer_path)
    report(completed, answer)
    # the one report line every paid lane prints (`LiveJourney#report_loop!`, through the evals
    # scorer's reader: spend, the sealed request's bytes). `reached` is the lane's one question —
    # the fetch completed as a read; `task_pass` records whether the model's answer.txt is the
    # page's sentence, and gates nothing.
    report_loop!(completed, reached: !reached.empty?, succeeded: completed.fetch("status") == "completed",
      task_pass: !answer.nil? && answer.include?(EVIDENCE))

    assert_equal "completed", completed.fetch("status"), "the loop did not finish: #{summarize(completed)}"

    # IT REACHED. A model that fetched the page with `curl` through `bash`
    # answered the task and never touched the tool; a refused call (a
    # private host, a cross-site redirect) answers an ERROR RESULT — which
    # the runner submits and the kernel settles as `completed`, with
    # `is_error` in its summary — so status alone would let a refused
    # fetch followed by a curl pass. The call that counts completed AND
    # was not an error.
    refute_empty reached, "it never read the page through web_fetch (curl, or a refused call): #{summarize(completed)}"

    # THE FETCH CARRIED THE PAGE: the call's output — the status line, then
    # the rendering (the mock journey's `split_status_line`) — holds the
    # page's own sentence. This is the flow the lane exists for.
    assert fetched.any? { |output| output.include?(EVIDENCE) },
      "no web_fetch output carries the page's sentence:\n#{fetched.map { |output| output.lines.first(6).join }.join("\n---\n")}"

    # THE ANSWER IS ON DISK: written, non-empty. Its words are the model's,
    # recorded above (`task_pass`), never a pin.
    assert_path_exists answer_path, "it never wrote answer.txt"
    refute_empty answer.to_s.strip, "answer.txt is empty"
  end

  private

    def completed_non_error_calls(row, tool_name)
      row.fetch("tasks").select do |t|
        t.fetch("kind") == "tool_task" && t.fetch("tool_name") == tool_name &&
          t.fetch("status") == "completed" && t.dig("result", "is_error") != true
      end
    end

    def report(row, answer)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live web_fetch -------------------------------------------"
      puts "model:  #{MODEL}"
      puts "page:   #{PAGE}"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:  #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "answer: #{answer.nil? ? "(no answer.txt)" : answer.strip.inspect}"
      puts "--------------------------------------------------------------"
    end
end
