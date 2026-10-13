require "test_helper"
require "support/live_journey"
require "support/evals/report_line"
require "json"

# A SESSION LONG ENOUGH TO OVERFLOW ITS CONTEXT, with a real model — the
# one thing no short journey exercises. Compaction arms only on FACTS
# (the request over the model's hard bound), so the task is sized to
# reach that fact: sixty files of twelve kilobytes, read and indexed one
# at a time, is past the composer's byte wall by the end.
#
# THE PROOF IS TWO-SIDED. The kernel must have compacted (a `context_compacted` item in the loop's
# own event stream), and the WORK must have survived it: every file indexed, each with the first
# line that only reading it could produce — a model whose history was summarized badly re-reads,
# skips, or invents. The summary carries POINTERS, never values: a model that invents a first line
# after a compaction is the summary's defect, and the lane fails on it — the fix is in the arm,
# never in the assertion.
#
# THE DELEGATE'S CONTENT, ONCE: under `E2E_COMPACTION=delegate` the journey writes `compaction:
# {mode: delegate}` into RHO_HOME before the daemon starts, so every wall is answered by rho's own
# `summarize_history` — a InferenceRequest on this lane under rho's own prompt — and the only place that
# prompt is judged on a real model is here: every summary row is a `tool_task` `completed`, every
# `context_compacted` says `delegate`, no `fallback` fired, and the index survives it. The mock can
# only echo that prompt back.
#
# Paid, local, opt-in, and long: E2E_LIVE=1. Budget: a hundred-odd
# rounds against the flash lane.
class LiveLongSessionTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  # `kernel` (the default) or `delegate`: which summarizer answers the wall.
  COMPACTION = ENV.fetch("E2E_COMPACTION", "kernel").freeze
  DELEGATE = "summarize_history".freeze
  # SIXTY FILES OF FORTY-FIVE KILOBYTES: the wall (a mebibyte of composed
  # history) is crossed after two dozen reads, and sixty keeps the paid
  # run short — the loop itself has no round ceiling.
  FILES = Integer(ENV.fetch("E2E_LONG_FILES", "60"))
  FILE_BYTES = 45 * 1024

  include E2E::LiveJourney

  def setup
    # `compaction-wall-long` is the bench's name for this lane: its $12
    # patience (`bench.yml` `cost_stop_usd_by_task`) and the report line's task.
    start_live_journey!(MODEL, home_prefix: "rho-live-long-e2e", task: "compaction-wall-long")
    return unless COMPACTION == "delegate"

    # BEFORE THE DAEMON STARTS: the flag is read at boot, and the delegate needs a model for its
    # InferenceRequest — this lane's. Over the dev set: a written file is the lane's own word.
    File.write(File.join(@home, "settings.json"),
      JSON.generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.compaction" => { "configuration" => { "mode" => "delegate", "model" => MODEL } } })), perm: 0o600)
  end

  def teardown = finish_live_journey!

  def test_a_session_that_overflows_its_context_is_compacted_and_the_work_survives
    connect_and_open_lane!
    project = File.join(@home, "project")
    corpus = File.join(project, "corpus")
    FileUtils.mkdir_p(corpus)
    expected = write_corpus(corpus)
    @daemon.control(:post, "/environment", body: { root: project })

    # THE CHECK IS THE DILIGENCE THE MODEL LACKS. A weak model indexes a
    # dozen files and says DONE; the acceptance check names what is
    # missing and fails until nothing is, so the session is driven past
    # the wall by the kernel's own --until ladder rather than by hope.
    File.write(File.join(project, "check.sh"), <<~SH)
      #!/bin/sh
      missing=0
      for f in corpus/doc-*.txt; do
        name=$(basename "$f")
        grep -q "^$name: " index.txt 2>/dev/null || { echo "missing: $name"; missing=$((missing + 1)); }
      done
      [ "$missing" -eq 0 ] && echo "all #{FILES} indexed" && exit 0
      echo "$missing files are not in index.txt yet"; exit 1
    SH
    task = <<~TEXT.strip
      The directory corpus/ contains #{FILES} text files named doc-001.txt
      through doc-#{format("%03d", FILES)}.txt. For EACH file, in numeric order:
      read the whole file with the read tool (not head, cat or grep), then
      append one line to index.txt of the form
      `doc-NNN.txt: <the file's first line, exactly>`. Read one file per
      tool call and append after each read — do not batch, do not guess a
      first line without reading, do not stop early. When all #{FILES} lines
      are in index.txt, reply DONE.
    TEXT
    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project,
      "--until", "sh check.sh", "--attempts", "6")
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    conversation_id = output[/^conversation:\s+(\S+)/, 1]
    loop_id = output[/^run:\s+(\S+)/, 1]

    done = await_loop_completion(loop_id, deadline: 3600)
    compactions = compaction_items(conversation_id)
    report(done, compactions)
    assert_equal "completed", done.fetch("status"), summarize(done)

    # THE KERNEL COMPACTED — at least once, on the fact, not a threshold.
    refute_empty compactions,
      "the context never overflowed: the task was too small for this model's window, " \
      "or compaction did not arm (#{done.fetch("tasks").size} tasks)"
    # ONE ARM, ONE PAYLOAD: every repair names how it was made and why it fired, from the closed
    # vocabularies; and at least one is the loop's OWN mid-turn repair, naming the round it made fit
    # — on this lane the provider's reported count arms it before any counter.
    compactions.each do |c|
      assert_includes %w[prune kernel delegate], c.dig("payload", "mode"), c.inspect
      assert_includes %w[wall manual overflow usage fallback], c.dig("payload", "trigger"), c.inspect
    end
    assert(compactions.any? { |c| c.dig("payload", "task_key") },
      "no mid-turn repair named its round: #{compactions.map { |c| c["payload"] }.inspect}")
    assert_the_delegate_answered_every_wall(done, compactions) if COMPACTION == "delegate"

    # THE WORK SURVIVED IT: every line, each first line real.
    index = File.join(project, "index.txt")
    assert_path_exists index, "index.txt was never written"
    lines = File.read(index, encoding: Encoding::UTF_8).lines.map(&:strip).reject(&:empty?)
    got = lines.to_h { |l| l.split(":", 2).map(&:strip) }
    duplicates = lines.tally.count { |_, n| n > 1 }
    puts "index:       #{lines.size} lines, #{got.size} distinct files, #{duplicates} duplicated lines"
    missing = expected.keys - got.keys
    wrong = expected.select { |name, first| got[name] && got[name] != first }.keys
    # WHAT A WRONG LINE LOOKS LIKE decides whose defect it is — the
    # oracle's, the model's, or the summary's — so the first few are
    # printed whole rather than counted.
    wrong.first(4).each { |name| puts "wrong:       #{name}: got #{got[name].inspect} expected #{expected[name].inspect}" }
    compactions.each do |c|
      puts "compaction:  #{c.dig("payload", "mode")}/#{c.dig("payload", "trigger")} #{c.slice("sequence", "payload").inspect[0, 400]}"
    end
    assert_empty missing, "#{missing.size} files were never indexed: #{missing.first(5).inspect}"
    assert_empty wrong, "#{wrong.size} first lines are wrong — invented, not read: #{wrong.first(5).inspect}"
  end

  private

    # UNDER THE DELEGATE FLAG every summary is rho's: each summarizing
    # row on the trace is the agent's own tool, completed; every item says
    # `delegate`; and the kernel never had to step in (`fallback` names a
    # delegate nobody answered — a dead rho, not this one). The pointer
    # discipline is the index assertion above, now against rho's prompt.
    def assert_the_delegate_answered_every_wall(row, compactions)
      summarizing = compactions.filter_map { |c| c.dig("payload", "summary_task_key") }
      refute_empty summarizing, "no wall was summarized: #{compactions.map { |c| c["payload"] }.inspect}"
      tasks = row.fetch("tasks").to_h { |t| [t.fetch("key"), t] }
      summarizing.each do |key|
        task = tasks.fetch(key) { flunk "summary row #{key} is not on the trace" }
        assert_equal %w[tool_task summarize_history completed],
          [task.fetch("kind"), task["tool_name"], task.fetch("status")],
          "rho's own summarizer answered #{key}: #{task.inspect}"
      end
      assert_equal ["delegate"], compactions.map { |c| c.dig("payload", "mode") }.uniq,
        "every wall was the delegate's: #{compactions.map { |c| c["payload"] }.inspect}"
      refute(compactions.any? { |c| c.dig("payload", "trigger") == "fallback" },
        "the kernel fell back for a delegate rho never answered: #{compactions.map { |c| c["payload"] }.inspect}")
    end

    # Sixty files whose first line is unique and unguessable, followed by
    # enough filler to make each read cost real context.
    def write_corpus(dir)
      (1..FILES).to_h do |i|
        name = format("doc-%03d.txt", i)
        first = "first-line-#{SecureRandom.hex(6)} of #{name}"
        body = Array.new(FILE_BYTES / 64) { |k| "line #{k} of #{name}: #{SecureRandom.alphanumeric(40)}" }
        File.write(File.join(dir, name), ([first] + body).join("\n") + "\n")
        [name, first]
      end
    end

    # The CONVERSATION's feed: a loop backing a turn has no feed of its own
    # (its address refuses `conversation_hosted`), and its items — the
    # compaction among them — ride its conversation's.
    def compaction_items(conversation_id)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation_id}/events" \
          "#{after ? "?after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows.select { |e| e["type"] == "context_compacted" })
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def report(row, compactions)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live long session ----------------------------------------"
      puts "model:       #{MODEL}"
      puts "status:      #{row.fetch("status")}"
      puts "rounds:      #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:       #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      modes = compactions.map { |c| c.dig("payload", "mode") }.tally.map { |mode, n| "#{mode}×#{n}" }.join(" ")
      puts "compactions: #{compactions.size}#{modes.empty? ? "" : " (#{modes})"} under #{COMPACTION}"
      # the one report line every paid lane prints (`LiveJourney#report_loop!`: the spend and the
      # sealed request's bytes through the evals reader); the pass column is the index assertion's,
      # read after this print.
      report_loop!(row, events: compactions, reached: !tools.empty?,
        succeeded: row.fetch("status") == "completed" && !compactions.empty?)
      puts "--------------------------------------------------------------"
    end
end
