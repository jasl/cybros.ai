require "test_helper"
require "support/live_journey"
require "support/fixture_project"
require "support/exit_long_pump"
require "support/evals/bench"
require "support/evals/corpus"
require "support/evals/seed"
require "support/evals/report_line"
require "net/http"
require "securerandom"
require "shellwords"
require "socket"

# GATE 3, THE LONG TASK (roadmap "Gate 3 — the round's exit"): a port of a
# ~300-line module and its tests that forces at least two compactions, a
# background dev server the model starts and reads, an approval in `ask`
# mode, and a standing goal (the suite must exit 0) that re-asks with
# evidence. Four pieces, each proven alone before this lane joined them:
# compaction on facts (`live_long_session`), the dev server
# (`live_processes`), the park under `ask` (`live_approval`), the `--until`
# ladder (`live_until`). ONE loop, ONE `rho do`, all four.
#
# THE PORT IS JS → RUBY WITH THE RUBY TESTS SHIPPED AND FROZEN. The codec
# (src/frame_codec.js: varint lengths, an escape table, a CRC-16, a frame
# reader that resyncs on a bad checksum) is fresh and bespoke; its Ruby
# suite (test/frame_codec_test.rb, 26 cases) was translated from the
# JavaScript's own behaviour and cross-checked byte for byte, so a faithful
# port passes it and nothing else does.
#
# THE BYTES THAT CROSS THE WALL ARE A VECTOR CORPUS. A module read three
# times is ~40 KiB — nothing on a 1 MiB wall — and compaction arms on FACTS
# alone (the composed request over MAX_COMPOSED_BYTES = 1,048,576). The
# sizing rule: bytes read through tool results must exceed
#   2 × MAX_COMPOSED_BYTES (1 MiB) + 2 × TAIL_BYTES (80 KiB) + the port's reads
# and 56 vector files of 45 KiB, read whole one per call and indexed into
# VECTORS.md, are 2.46 MiB > 2.16 MiB + ≈ 0.2 MiB. The first wall prunes
# the oldest results down to the 80 KiB tail; the next mebibyte of reads
# crosses it again. A fact-driven wall on a read-heavy loop PRUNES (the
# arm prefers it whenever prunable bytes cover the overshoot), so this
# lane asserts `context_compacted` ≥ 2 of ANY mode with a fact trigger and
# prints the modes; the kernel and delegate SUMMARIES are the gallery's,
# through the manual door.
#
# THE INDEX LINE NEEDS THE WHOLE FILE. Gate 3's first Long read the 56 vectors with `limit: 1` on
# both flash models — 70-byte results, the index still exact, the composed request at 105–280 KB,
# never near the wall; its second cut indexed the LAST line, and the read tool's own footer named
# the total, so one `offset: <total>` window fetched it for 70 bytes. The index line now holds the
# file's FIRST line and its MARKER line — one `marker-<hex>` line at a position drawn uniformly per
# file at write time (lines 2..N-1), recorded nowhere but in the file. Each file is 723 lines / ≈
# 47.5 KB, under the read tool's 2 000-line / 50 KiB window, so ONE bare `read` returns it whole
# with no footer — the only single call that certainly finds the marker; a windowed search pages
# from the top and pays on average half the file, ≈ 1.3 MiB over 56 — one wall, not two. The
# two-compaction property is a property of the corpus only when the files are read whole, which is
# why the pump below stands guard.
#
# THE PUMP IS THE ONE SCRIPTED HUMAN STEP. `--approval ask` is a `rho do` knob for the turn, and
# under `ask` every runner call with an EFFECT parks for a person (rho's rules allow its read-only
# tools — `read`, `ls`, `grep`, `find`, `read_process` — so the writes, the commands and the server
# park, the reads run); this journey decides every park through rho's own verbs and prints each one:
# `rho deny` with a reason for a `bash`/`start_process` command that reads the corpus with a shell
# verb (E2E::ExitLongPump — the person saying "use the read tool", which the model reads in the next
# tool result), `rho approve` for everything else. Asserted: at least one park; every park's
# `approval.origin == "agent"` — the fact records the approver's KIND (`human|agent`, Tasks::Approve
# and Tasks::Deny alike), and rho's verb is the agent application's grant, as live_approval pins;
# the `check-N` rows the goal's author appended carry `origin == "author"` and never parked; a
# kernel-planted `k` row, if any, is `origin == "kernel"`. A denial is a recorded human act, not a
# pass condition: the report prints `denied: N` and asserts nothing on it — a model that gives up
# after one fails at the acceptance as today. The report also prints the bytes the model's reads
# carried per vector file and how many files were read whole (no assertion; the reading behind the
# compaction leg).
#
# THE SERVER'S PROOF IS ON DISK. server/app.rb prints an unguessable
# SPEC-TOKEN the journey seeded outside the project root, printed three
# seconds AFTER `listening on` so it never rides start_process's own
# answer and only `read_process` reaches it; the port must carry it as
# FrameCodec::SPEC_TOKEN, the acceptance check compares, and the trace
# must hold a `start_process` and a `read_process` row completed.
#
# WHAT A RED RUN PRINTS: the report (rounds, calls, compactions by mode,
# parks, the ladder's checks, the suite's verdict, the port's head) and
# then the first assertion that failed — the suite's output, the changed
# specification files, the missing or invented index lines, the trace.
#
# Paid, local, opt-in, and LONG: E2E_LIVE=1. Budget: ≈ 80–90 rounds,
# ≈ $3–6 and 40–60 minutes per model on the flash tier; the pump adds a
# `rho approve` spawn (≈ 1.5 s) per runner call. E2E_EXIT_LONG_VECTORS=12
# is the smoke (no wall crossed: the compaction assertion is expected red).
class LiveExitLongTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  VECTORS = Integer(ENV.fetch("E2E_EXIT_LONG_VECTORS", "56"))
  VECTOR_BYTES = 45 * 1024
  SPEC_TOKEN = SecureRandom.hex(8).freeze
  SUITE = "ruby -Ilib -Itest test/all.rb".freeze
  # THE FIXTURE IS THE CORPUS'S: `e2e/evals/tasks/exit-long/` — the codec and its shipped suite
  # under `environment/`, the vectors, the server, the gate and the brief from `environment.rb` over
  # a Seed (the token is the seed's secret, written to `<home>/spec-seed` by the generator; the port
  # the seed's).
  FIXTURE = E2E::Evals::Corpus.load_task(File.join(E2E::Evals::Corpus::DIR, "exit-long"),
    canary: E2E::Evals::Bench.read.canary)
  # Frozen: the specification, the gate, and the brief.
  SHIPPED = %w[src/frame_codec.js test/frame_codec_test.rb test/spec_token_test.rb test/all.rb check.sh PORT.md].freeze
  # Under the journey's 5400 s; teardown keeps its own 600 s after it.
  PUMP_DEADLINE_SECONDS = 5000

  Park = Data.define(:key, :tool, :argument, :verb)

  include E2E::LiveJourney

  # `exit-long` is the bench's name for this lane: its $20 patience (`bench.yml`
  # `cost_stop_usd_by_task`) and the report line's task.
  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-exit-long-e2e", task: "exit-long")

  def teardown = finish_live_journey!

  def test_a_real_model_ports_a_module_across_two_compactions_a_server_and_a_park
    connect_and_open_lane!
    port = free_port
    # THE TOKEN LIVES OUTSIDE THE PROJECT ROOT: the server reads it, the
    # gate compares against it, the read tool cannot reach it (the
    # corpus's generator writes `<home>/spec-seed` from the seed's secret).
    seed = E2E::Evals::Seed.new(home: @home, project: File.join(@home, "codec"), port: port, secret: SPEC_TOKEN, model: MODEL)
    # Generated ONCE: the vectors are random per run, so the files the
    # lane compares against are the ones the project holds.
    project = FIXTURE.write_environment(@home, "codec", seed)
    files = project.files
    # The vector FILES alone: the corpus writes `spec/vectors/INDEX` beside them
    # (`evals/tasks/exit-long/environment.rb`), a list no model can index; `sizes` and
    # `vector_reads` key off this hash.
    vectors = files.select { |path, _| path.start_with?("spec/vectors/vec-") }
      .to_h { |path, contents| [File.basename(path), contents] }
    expected = vectors.transform_values { |contents| index_line(contents) }
    # The bytes ONE WHOLE READ carries: the read tool joins the lines it
    # kept with "\n" and never re-adds the file's final newline (the
    # 12-vector smoke read every file whole at exactly file bytes − 1), so
    # the file's own bytesize would count no read as whole.
    sizes = vectors.transform_values { |contents| contents.chomp("\n").bytesize }
    # THE SUITE FAILS BEFORE, or the task is not the task.
    refute project.passes?(SUITE), "the fixture project was already green"
    @daemon.control(:post, "/environment", body: { root: project.root })

    output, status = @daemon.cli("do", task_text(port), "--model", MODEL, "--dir", project.root,
      "--approval", "ask", "--until", "sh check.sh", "--attempts", "6")
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    assert_match(/^until:\s+sh check\.sh \(6 checks, in #{Regexp.escape(project.root)}\)/, output, output)
    conversation_id = output[/^conversation:\s+(\S+)/, 1]
    loop_id = output[/^loop:\s+(\S+)/, 1]
    refute_nil loop_id, "rho do printed no loop id:\n#{output}"

    # The park loop blocks for the loop's whole life: the cost stop rides
    # the spend watch beside it (`watching_spend`), never the kernel.
    parks = watching_spend(loop_id) { decide_every_park!(loop_id) }
    done = loop_row(loop_id)
    items = feed(conversation_id)
    compactions = items.select { |item| item["type"] == "context_compacted" }
    watched, = rho_watch(loop_id, "--timeout", "30")
    reads = vector_reads(loop_id, done.fetch("tasks"), sizes)
    report(done, compactions, parks, reads, watched, project)
    tasks = done.fetch("tasks")
    keys = tasks.to_h { |t| [t.fetch("key"), t] }

    assert_equal "completed", done.fetch("status"), summarize(done)

    # THE ACCEPTANCE: the suite's own exit, the specification untouched,
    # the index real, the server's token in the port.
    assert project.passes?(SUITE),
      "the suite is still red after the loop reported #{done.fetch("status")}:\n#{project.run(SUITE).first}"
    assert_empty project.changed(SHIPPED), "it changed the specification instead of the port"
    assert_the_index_is_real(project, expected)
    assert_equal SPEC_TOKEN, spec_token_on_disk(project), "the port does not carry the token the server printed"

    # THE SERVER: started and read by the model, listed and killed by the person.
    tools = tasks.select { |t| t.fetch("kind") == "tool_task" }
    started = tools.find { |t| t["tool_name"] == "start_process" }
    refute_nil started, "the model never called start_process: #{tools.map { |t| t["tool_name"] }.uniq.inspect}"
    assert_equal "completed", started.fetch("status"), started.inspect
    read = tools.find { |t| t["tool_name"] == "read_process" }
    refute_nil read, "the model never read the server's output with read_process"
    assert_equal "completed", read.fetch("status"), read.inspect
    # The line names the process's HOST as `owner` (the conversation `rho
    # do` opened; `Processes::Registry#owner_for`) and the loop beside it
    # (`Extensions::Processes::Commands#process_line`): listed running,
    # and this loop's.
    listing, = @daemon.cli("processes")
    assert_match(/^p\d+  running  pid \d+  owner \S+  loop #{Regexp.escape(loop_id)}\b/, listing, listing)
    id = listing[/^(p\d+)  running/, 1]
    assert_equal "ok\n", Net::HTTP.get(URI("http://127.0.0.1:#{port}/health"))
    killed, = @daemon.cli("kill", id)
    assert_match(/^#{id}  exited/, killed, killed)
    assert_raises(Errno::ECONNREFUSED) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/health")) }

    # THE LADDER: the goal's author's checks, pre-approved by origin, and
    # the summary that carries the answer.
    assert keys.key?("check-1"), "no acceptance check ran: #{keys.keys.inspect}"
    assert_equal "completed", keys.fetch("check-1").fetch("status"), keys.fetch("check-1").inspect
    assert keys.key?("summary"), "no summary round: #{keys.keys.inspect}"
    assert_equal "completed", keys.fetch("summary").fetch("status"), keys.fetch("summary").inspect
    checks = tasks.select { |t| t.fetch("key").match?(/\Acheck-\d+\z/) }
    checks.each do |check|
      assert_equal "author", check.dig("approval", "origin"), "the author's check was not pre-approved: #{check.inspect}"
    end

    # THE PARKS — the one scripted intervention: a person decided every
    # runner call through `rho approve` / `rho deny`, and only runner calls
    # parked. The fact's origin is the approver's KIND (`human|agent`),
    # never "person": rho's verb is the agent application's grant —
    # live_approval's pin; Tasks::Deny stamps the same origin as Approve.
    refute_empty parks, "nothing parked under --approval ask"
    parks.each do |park|
      assert_equal "agent", keys.fetch(park.key).dig("approval", "origin"),
        "a park was not decided through rho approve: #{keys.fetch(park.key).inspect}"
    end
    assert_empty parks.map(&:key) & checks.map { |t| t.fetch("key") }, "an acceptance check parked"
    tasks.select { |t| t.fetch("key").match?(/\Ak\d+\z/) && t["approval"] }.each do |summary|
      assert_equal "kernel", summary.dig("approval", "origin"), "a kernel-planted row was not the kernel's: #{summary.inspect}"
    end

    # THE KERNEL DROVE EVERY ROUND: no round failed, the loop rests holding
    # for nobody, and the feed asked for a person only to approve.
    failed_rounds = tasks.select { |t| t.fetch("kind") == "model_task" && t.fetch("status") != "completed" }
    assert_empty failed_rounds.map { |t| describe_task(t) }, "a round did not complete: #{summarize(done)}"
    assert_nil done["attention"], "the loop rests holding for a person: #{done["attention"].inspect}"
    other = items.select { |item| item["type"] == "attention_required" && item.dig("payload", "reason") != "approval_required" }
    assert_empty other.map { |item| item["payload"] }, "the feed called for a person outside the approval park"

    # THE KERNEL COMPACTED, TWICE, ON THE FACT — never a threshold, never
    # the manual door; the modes are the arm's choice and are printed.
    # LAST, so the 12-vector smoke (no wall crossed, this block's expected
    # red) proves everything above it in five minutes.
    assert_operator compactions.size, :>=, 2,
      "the context did not overflow twice: #{compactions.size} repairs over #{tasks.size} tasks " \
      "(the corpus was too small for this model's window, or compaction did not arm)"
    compactions.each do |c|
      assert_includes %w[prune kernel delegate], c.dig("payload", "mode"), c.inspect
      assert_includes %w[wall usage overflow], c.dig("payload", "trigger"), c.inspect
    end
    assert(compactions.any? { |c| c.dig("payload", "task_key") },
      "no mid-turn repair named its round: #{compactions.map { |c| c["payload"] }.inspect}")
  end

  private

    # ---- the fixture ----------------------------------------------------

    def task_text(port)
      <<~TEXT.strip
        This directory holds a frame codec written in JavaScript
        (src/frame_codec.js) and a Ruby test suite for the same codec
        (test/frame_codec_test.rb) that expects lib/frame_codec.rb, which
        does not exist yet. PORT.md is the brief. Do these three things, in
        this order.

        1. THE CORPUS. spec/vectors/ holds #{VECTORS} vector files, vec-01.txt
           through vec-#{format("%02d", VECTORS)}.txt. For EACH file, in numeric
           order: read the whole file with the read tool (not head, cat or
           grep), then append one line to VECTORS.md of the form
           `vec-NN.txt: <the file's first line, exactly> | <the file's
           marker line — the one line starting with marker->`. Read one
           file per tool call and append after each read — do not batch,
           do not guess a line without reading, do not stop early.

        2. THE SPEC SERVER. Start `ruby server/app.rb #{port}` with the
           start_process tool (pass wait_for "listening on"), then read its
           output with read_process. It prints a line `SPEC-TOKEN: <token>`;
           you will need that token. Leave the server running — do not stop
           it.

        3. THE PORT. Write lib/frame_codec.rb, a Ruby port of
           src/frame_codec.js, with `FrameCodec::SPEC_TOKEN` set to the token
           the server printed. The shipped tests are the specification — do
           not change anything under test/ or src/. Run
           `ruby -Ilib -Itest test/all.rb` and fix the port until it passes.

        Each tool call may wait for my approval — that is expected; do not
        work around it. Reply DONE when the suite passes.
      TEXT
    end

    # The index line a vector file owes: its first line and its marker
    # line, the shape the task text names and check.sh compares.
    def index_line(contents)
      lines = contents.lines(chomp: true)
      "#{lines.first} | #{lines.find { |line| line.start_with?("marker-") }}"
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    # ---- the pump: the person at the terminal, deciding every call -------

    # Polls the daemon's own row every two seconds and answers each new
    # park through `rho approve` — or `rho deny` with a reason for a shell
    # read of the corpus (E2E::ExitLongPump); a re-park is approved once
    # more, as a person would after reading `rho task` again. Returns when
    # the row is complete; flunks on any hold the pump cannot answer, or
    # the deadline.
    def decide_every_park!(loop_id)
      parks = []
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PUMP_DEADLINE_SECONDS
      loop do
        row = followed(loop_id)
        return parks if row && row["complete"]

        reason = row&.dig("attention", "reason")
        if reason == "approval_required"
          Array(row.dig("attention", "blocked_task_keys")).each do |key|
            next if parks.any? { |park| park.key == key }

            parks << decide_one!(loop_id, key)
          end
        elsif reason
          flunk "the loop holds for something the pump cannot answer (#{reason}): #{summarize(loop_row(loop_id))}"
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit
          flunk "the loop never completed under the pump; #{parks.size} parks; #{summarize(loop_row(loop_id))}"
        end

        sleep 2
      end
    end

    # The denial's line is the verb's own contract (live_approval pins the
    # same `failed (approval_denied)`), not a new pass condition on the
    # lane; the reason is positional — `deny LOOP_ID TASK_KEY [REASON]`.
    def decide_one!(loop_id, key)
      detail = task_detail(loop_id, key)
      input = Hash(detail["tool_input"])
      argument = (input["command"] || input["path"] || input["id"] || input["pattern"]).to_s
      verb = E2E::ExitLongPump.bypass?(detail["tool_name"], input) ? "deny" : "approve"
      puts "park:   #{key}  #{detail["tool_name"]} #{argument[0, 80].inspect}  → #{verb}"
      if verb == "deny"
        printed = run_verb!("deny", loop_id, key, E2E::ExitLongPump::REASON)
        assert_match(/^status:\s+failed \(approval_denied\)$/, printed, printed)
      else
        printed = run_verb!("approve", loop_id, key)
        printed = run_verb!("approve", loop_id, key) if printed.match?(/^status:\s+needs_approval/)
        assert_match(/^status:\s+(dispatched|running)$/, printed, printed)
      end
      Park.new(key: key, tool: detail["tool_name"], argument: argument, verb: verb)
    end

    def run_verb!(verb, loop_id, key, *rest)
      printed, status = @daemon.cli(verb, loop_id, key, *rest)
      assert_predicate status, :success?, "rho #{verb} failed:\n#{printed}"
      printed
    end

    # The daemon's rows are keyed by the HOST — the conversation `rho do`
    # opened — and carry every loop that backed it, so a loop id finds
    # its row through `loops`, the way `rho watch` does.
    def followed(loop_id)
      @daemon.control(:get, "/loops").fetch("loops").find do |row|
        row.fetch("public_id") == loop_id || Array(row["loops"]).include?(loop_id)
      end
    end

    def task_detail(loop_id, key)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}/tasks/#{key}").fetch("task")
    end

    # ---- what the loop left behind ---------------------------------------

    # The CONVERSATION's feed: a loop backing a turn has no feed of its
    # own, and its items — the compactions among them — ride its
    # conversation's.
    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    # THE BYTES THE MODEL'S READS CARRIED, per vector file: the stored
    # result of every `read` whose path is a vector (the task read serves
    # the row's own body, which a prune never rewrites — a prune is a
    # render), summed per file; a read is WHOLE when its own bytes cover
    # what one whole read returns (`sizes`: the file less its final
    # newline — a bare whole read has no footer, so equality; a windowed
    # one never reaches it). Files never read count as 0. A diagnostic
    # for the report, never an assertion.
    def vector_reads(loop_id, tasks, sizes)
      reads = tasks.select { |t| t.fetch("kind") == "tool_task" && t["tool_name"] == "read" }
        .filter_map do |t|
          detail = task_detail(loop_id, t.fetch("key"))
          name = detail.dig("tool_input", "path").to_s[/(vec-\d\d\.txt)\z/, 1]
          [name, detail["output"].to_s.bytesize] if name && sizes.key?(name)
        end
      by_file = reads.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      {
        totals: sizes.keys.map { |name| by_file.fetch(name, []).sum },
        whole: sizes.count { |name, size| by_file.fetch(name, []).any? { |bytes| bytes >= size } },
        calls: reads.size,
      }
    end

    def median(values)
      sorted = values.sort
      return 0 if sorted.empty?

      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    end

    # THE WORK SURVIVED THE COMPACTIONS: every vector indexed, each line
    # the first line and the marker line only reading the whole file
    # could produce.
    # A wrong line is printed whole — whose defect it is (the model's, or
    # the summary's) is what the shape of the wrong line says.
    def assert_the_index_is_real(project, expected)
      index = File.join(project.root, "VECTORS.md")
      assert_path_exists index, "VECTORS.md was never written"
      lines = File.read(index, encoding: Encoding::UTF_8).lines.map { |l| l.strip.sub(/\A[-*]\s+/, "") }.reject(&:empty?)
      got = lines.filter_map { |l| l.split(":", 2).map(&:strip) if l.include?(":") }.to_h
      duplicates = lines.tally.count { |_, n| n > 1 }
      puts "index:   #{lines.size} lines, #{got.size} distinct files, #{duplicates} duplicated lines"
      missing = expected.keys - got.keys
      wrong = expected.select { |name, line| got[name] && got[name] != line }.keys
      wrong.first(4).each { |name| puts "wrong:   #{name}: got #{got[name].inspect} expected #{expected[name].inspect}" }
      assert_empty missing, "#{missing.size} vector files were never indexed: #{missing.first(5).inspect}"
      assert_empty wrong, "#{wrong.size} index lines are wrong — invented or read in part, not whole: #{wrong.first(5).inspect}"
    end

    def spec_token_on_disk(project)
      project.run(%(ruby -Ilib -e 'require "frame_codec"; print FrameCodec::SPEC_TOKEN')).first.strip
    end

    # WHAT IT DID, printed whatever the verdict.
    def report(row, compactions, parks, reads, watched, project)
      tasks = row.fetch("tasks")
      tools = tasks.select { |t| t.fetch("kind") == "tool_task" }
      checks = tasks.select { |t| t.fetch("key").match?(/\Acheck-\d+\z/) }
      puts "\n--- live exit: long --------------------------------------------"
      puts "model:       #{MODEL}"
      puts "status:      #{row.fetch("status")}"
      puts "rounds:      #{tasks.count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:       #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      modes = compactions.map { |c| "#{c.dig("payload", "mode")}/#{c.dig("payload", "trigger")}" }.tally
      puts "compactions: #{compactions.size}#{modes.empty? ? "" : " (#{modes.map { |m, n| "#{m}×#{n}" }.join(" ")})"}"
      puts "parks:       #{parks.size} (#{parks.map(&:tool).tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "denied:      #{parks.count { |park| park.verb == "deny" }}"
      totals = reads.fetch(:totals)
      puts "read bytes:  #{totals.min}/#{median(totals)}/#{totals.max} per file over #{reads.fetch(:calls)} vector reads, " \
           "whole-file reads: #{reads.fetch(:whole)} of #{VECTORS}"
      puts "checks:      #{checks.map { |t| "#{t["key"]}=#{t["status"]}#{t.dig("error", "key") ? "!#{t.dig("error", "key")}" : ""}" }.join(" ")}"
      puts "watched:     #{watched.to_s.scan(/check \d\/\d: [^\n]+/).join(" | ")}"
      puts "suite:       #{project.passes?(SUITE) ? "green" : "RED"}"
      # the one report line every paid lane prints (`LiveJourney#report_loop!`: the spend and the
      # sealed request's bytes through the evals reader).
      report_loop!(row, events: compactions, reached: !tools.empty?,
        succeeded: row.fetch("status") == "completed", task_pass: project.passes?(SUITE))
      puts "--- frame_codec.rb after (first 40 lines) -----------------------"
      port = File.join(project.root, "lib/frame_codec.rb")
      puts(File.file?(port) ? File.read(port, encoding: Encoding::UTF_8).lines.first(40).join : "(never written)")
      puts "----------------------------------------------------------------"
    end
end
