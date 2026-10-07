desc "Give a REAL model a real piece of development work through rho's own " \
     "tools and check the result on disk (paid, local): E2E_LIVE=1"
task :live_agent_run do
  run_e2e_tests("live_agent_run_test")
end

desc "Real models author code and result-driven steps through rho (paid): " \
     "RAILS_ENV=development E2E_LIVE=1 [E2E_RESULT_DAG_ONLY=dynamic,pipeline]"
task :live_result_dag do
  require_relative "../support/result_dag"
  E2E::ResultDag.validate!
  run_e2e_tests("live_result_dag_test", journey_seconds: E2E::ResultDag.selected.length * 420 + 120,
    model_overrides: E2E::ResultDag.model_overrides(nexus_root: File.expand_path("../../nexus", __dir__)))
end

Minitest::TestTask.create(:live_result_dag_test) do |t|
  t.test_globs = ["test/live_result_dag_test.rb"]
end

Minitest::TestTask.create(:live_agent_run_test) do |t|
  t.test_globs = ["test/live_agent_run_test.rb"]
end

desc "A REAL model asks a person a question it cannot answer itself, and " \
     "uses what they said (paid, local): E2E_LIVE=1"
task :live_human_in_the_loop do
  run_e2e_tests("live_human_in_the_loop_test")
end

Minitest::TestTask.create(:live_human_in_the_loop_test) do |t|
  t.test_globs = ["test/live_human_in_the_loop_test.rb"]
end

desc "Give a REAL model a project it has never seen with a failing suite " \
     "and no statement of the bug (paid, local): E2E_LIVE=1"
task :live_debugging do
  run_e2e_tests("live_debugging_test")
end

Minitest::TestTask.create(:live_debugging_test) do |t|
  t.test_globs = ["test/live_debugging_test.rb"]
end

# GATE 3, THE ROUND'S EXIT: three graded real development tasks on both
# weak models, each driven through exe/rho, each judged by its own
# acceptance command. The Small task IS live_debugging (a never-seen
# project, one defect in one file, the suite's exit as the verdict), by
# alias: a second file would double the sweep's glob.
desc "Gate 3 Small: live_debugging by its exit name (paid): E2E_LIVE=1"
task live_exit_small: :live_debugging

desc "Gate 3 Medium: a multi-file feature against shipped red tests in a never-seen project, " \
     "the suite's exit as the verdict (paid, ≈ 10 min): E2E_LIVE=1"
task :live_exit_medium do
  run_e2e_tests("live_exit_medium_test", journey_seconds: 1800)
end

Minitest::TestTask.create(:live_exit_medium_test) do |t|
  t.test_globs = ["test/live_exit_medium_test.rb"]
end

desc "Gate 3 Long: a JS→Ruby port across two fact-driven compactions, a dev server the model starts " \
     "and reads, every call approved under --approval ask, --until as the standing goal " \
     "(paid, ≈ 40–60 min and ≈ $3–6 per model; E2E_EXIT_LONG_VECTORS=12 is the smoke): E2E_LIVE=1"
task :live_exit_long do
  run_e2e_tests("live_exit_long_test", journey_seconds: 5400, teardown_seconds: 600)
end

Minitest::TestTask.create(:live_exit_long_test) do |t|
  t.test_globs = ["test/live_exit_long_test.rb"]
end

desc "The loop-shape gallery: nine shapes on E2E_LIVE_MODEL, each loop's graph exported to " \
     "artifacts/gallery/ and asserted against its expected shape (paid, ≈ 30–40 min per model): " \
     "E2E_LIVE=1 [E2E_GALLERY_ONLY=linear,until_gate]"
task :live_gallery do
  run_e2e_tests("live_gallery_test", journey_seconds: 3600, teardown_seconds: 300)
end

Minitest::TestTask.create(:live_gallery_test) do |t|
  t.test_globs = ["test/live_gallery_test.rb"]
end

# THE EVALS SUITE: the corpus under evals/tasks, the frozen evals/bench.yml, one paid lane
# (evals/lane_test.rb — outside test/, so neither the manifest nor the sweep's glob sees it) whose
# world's patience is SIZED FROM THE PLAN — 2 × Σ deadline_seconds over the selected (task × model ×
# style × runs), because a red run awaits twice under one deadline, plus boot/teardown slack — and
# three no-boot readers. The runbook: docs/evals-runbook.md. `rake -T` loads files only.
def evals_bench
  require_relative "../support/evals/bench"
  require_relative "../support/evals/corpus"
  require_relative "../support/evals/plan"
  E2E::Evals::Bench.read
end
private :evals_bench

# The run list: the mock corpus plus each container family the environment
# names (E2E_EVALS_TB_CORPUS the terminal-bench checkout, E2E_EVALS_RAILS_CORPUS
# the Agents-on-Rails one) — one list, so a glob selects across families.
def evals_corpus(bench) = E2E::Evals::Corpus.load_all(bench: bench)
private :evals_corpus

desc "The evals runner: the selected corpus through exe/rho on the bench's models, one record per run " \
     "(paid): E2E_LIVE=1 rake \"evals[<task-glob>,<model>]\" — both optional; a glob matches the name or " \
     "family/name (terminal-bench/*); E2E_EVALS_TASKS/_MODELS/_STYLES/_RUNS/_LABEL narrow the bench; " \
     "E2E_EVALS_CANDIDATE=<row>/<id> reads a harness candidate under the pack word (the RUN step's door); " \
     "E2E_EVALS_FALLBACKS=off runs the bench's declared refusal fallbacks off (the control); " \
     "E2E_EVALS_TB_CORPUS / E2E_EVALS_RAILS_CORPUS add the container families (docker)"
task :evals, [:tasks, :model] do |_t, args|
  ENV["E2E_EVALS_TASKS"] = args[:tasks] unless args[:tasks].to_s.empty?
  ENV["E2E_EVALS_MODELS"] = args[:model] unless args[:model].to_s.empty?
  bench = evals_bench
  selection = bench.subset(ENV)
  runs = E2E::Evals::Plan.build(evals_corpus(bench), bench, selection)
  abort "evals: E2E_EVALS_TASKS=#{selection.tasks_glob.inspect} on #{selection.models.join(",")} names no run" if runs.empty?
  seconds = E2E::Evals::Plan.journey_seconds(runs)
  puts "evals: #{runs.size} runs (#{E2E::Evals::Plan.groups(runs).size} daemon configurations) on " \
       "#{selection.models.join(",")} × #{selection.styles.join(",")} × #{selection.runs}" \
       "#{selection.doors.map { |door| "; #{door}" }.join}; " \
       "journey #{seconds} s; records → #{selection.run_dir}"
  run_e2e_tests("evals_lane_test", journey_seconds: seconds, teardown_seconds: 600)
end

Minitest::TestTask.create(:evals_lane_test) do |t|
  t.test_globs = ["evals/lane_test.rb"]
end

desc "List the evals corpus: name, family, capability, difficulty, driver, tiers, deadline, verification (no boot); " \
     "E2E_EVALS_TB_CORPUS / E2E_EVALS_RAILS_CORPUS add the container families"
task :evals_tasks do
  bench = evals_bench
  corpus = evals_corpus(bench)
  puts format("%-32s %-14s %-40s %-7s %-20s %-13s %6s  %s", "task", "family", "capability", "diff", "driver", "tiers", "s", "verify")
  corpus.tasks.each do |task|
    puts format("%-32s %-14s %-40s %-7s %-20s %-13s %6d  %s", task.name, task.family, task.capability, task.difficulty,
      task.driver, task.tiers.join("+"), task.deadline_seconds, task.verification ? "yes" : "no")
  end
  puts "\n#{corpus.tasks.size} tasks in #{corpus.families.size} families; bench #{bench.short_digest} (version #{bench.version}); " \
       "tiers strong=#{bench.tiers.fetch("strong").join(",")} floor=#{bench.tiers.fetch("floor").join(",")}; " \
       "named-only strong=#{bench.named_only.fetch("strong").join(",")} floor=#{bench.named_only.fetch("floor").join(",")}"
  puts "terminal-bench: #{bench.terminal_bench_names.size} names frozen (#{bench.terminal_bench.fetch("dataset")} at " \
       "#{bench.terminal_bench.fetch("commit")[0, 12]}); #{ENV["E2E_EVALS_TB_CORPUS"].to_s.empty? ? "not loaded — E2E_EVALS_TB_CORPUS names the checkout" : "loaded from #{ENV["E2E_EVALS_TB_CORPUS"]}"}"
end

desc "The per-model scorecards for one label under artifacts/evals/runs (no boot): rake \"evals_scorecard[<label>]\""
task :evals_scorecard, [:label] do |_t, args|
  require_relative "../support/evals/scorecard"
  bench = evals_bench
  label = args[:label].to_s
  abort "evals_scorecard needs a label: the runs/ directory name (rake evals_ledger lists them)" if label.empty?
  E2E::Evals::Scorecard.write(File.join(bench.runs_dir, label), bench: bench).each do |path|
    puts "wrote #{path}"
    puts
    puts File.read(path, encoding: Encoding::UTF_8)
  end
end

desc "Re-score one label's records of a task from their stored traces (no boot, no paid call): " \
     "rake \"evals_rescore[<label>,<task-glob>]\" — one NEW line per record (rescored: true; the newer wins); " \
     "a record of another bench is refused unless the third argument is `force` (a harness fault's re-score)"
task :evals_rescore, [:label, :task, :force] do |_t, args|
  # The whole suite: a task's expected.rb reads `Predicates` and `Gallery`.
  require_relative "../support/evals"
  bench = evals_bench
  label = args[:label].to_s
  glob = args[:task].to_s
  abort "evals_rescore needs a label and a task glob: rake \"evals_rescore[<label>,<task-glob>]\"" if label.empty? || glob.empty?
  corpus = evals_corpus(bench)
  written = E2E::Evals::Rescore.call(File.join(bench.runs_dir, label), glob, corpus: corpus,
    artifacts_dir: File.expand_path("../artifacts/evals", __dir__), bench_digest: bench.digest, force: args[:force] == "force")
  written.each { |record| puts E2E::Evals::ReportLine.render(record) }
  puts "#{written.size} record(s) re-scored under #{label}; then: rake \"evals_scorecard[#{label}]\" && rake evals_ledger"
end

# THE HARBOR CELL — THE BENCHMARK DOOR: `harbor run -a acp:rho` over the evals image's
# `rho-acp-launch`, the pairing sidecar beside it, the trials imported into the runs ledger. `dry`
# (the default) is the whole plan on paper and runs nothing; `run` is the paid cell as a LANE
# (evals/harbor_acp_lane_test.rb — outside test/ like the evals lane): the world booted here by
# `run_e2e_tests` with its patience sized from the plan (2 × Σ deadline × k plus the slack,
# `Cell#journey_seconds`), priced and its provider enabled by the lane, harbor and the sidecar
# beside it on a box with docker and harbor — the box binds the world 0.0.0.0 (E2E_NEXUS_BIND) and
# names its LAN IP (E2E_EVALS_HARBOR_NEXUS_HOST) as the address harbor's containers reach it by;
# `import` reads a finished job dir offline. The support file is required inside the task: `rake -T`
# loads files only.
desc "The harbor ACP cell (the benchmark door): rake \"evals_harbor_acp[dry]\" prints the registry entry, the " \
     "harbor command and the sidecar plan (no boot, nothing runs); [run] boots a world and runs the lane " \
     "(evals/harbor_acp_lane_test.rb): harbor from the job dir beside the pairing sidecar, the trials imported " \
     "(paid; docker + harbor + E2E_LIVE=1 + the provider key; on a box E2E_NEXUS_BIND=0.0.0.0 and " \
     "E2E_EVALS_HARBOR_NEXUS_HOST=<LAN IP>); [import] reads a finished job dir into the runs ledger. " \
     "E2E_EVALS_TB_CORPUS names the checkout; E2E_EVALS_TASKS/_MODELS/_RUNS/_LABEL narrow the cell; " \
     "E2E_EVALS_HARBOR_JOBS_DIR the jobs dir; E2E_EVALS_HARBOR_NEXUS_URL overrides the containers' address whole"
task :evals_harbor_acp, [:mode] do |_t, args|
  require_relative "../support/evals/harbor_acp"
  bench = evals_bench
  mode = args[:mode].to_s.empty? ? "dry" : args[:mode].to_s
  abort "evals_harbor_acp: the mode is dry, run or import, got #{mode.inspect}" unless %w[dry run import].include?(mode)
  cell = E2E::Evals::HarborAcp::Cell.plan(bench: bench, env: ENV)
  case mode
  when "dry"
    puts cell.describe
  when "run"
    puts "harbor acp: #{cell.tasks.size} task(s) × k=#{cell.runs} on #{cell.model}; journey #{cell.journey_seconds} s; " \
         "job dir #{cell.job_dir}; records → #{cell.run_dir}"
    run_e2e_tests("harbor_acp_lane_test", journey_seconds: cell.journey_seconds, teardown_seconds: 600)
  when "import"
    records = E2E::Evals::HarborAcp.import!(cell)
    abort "evals_harbor_acp: no #{E2E::Evals::HarborAcp::EVENTS} under #{cell.job_dir}" if records.empty?
    records.each { |record| puts E2E::Evals::ReportLine.render(record) }
    puts "#{records.size} record(s) under #{cell.run_dir}; then: rake evals_ledger"
  else
    abort "evals_harbor_acp: unreachable mode #{mode.inspect}"
  end
end

Minitest::TestTask.create(:harbor_acp_lane_test) do |t|
  t.test_globs = ["evals/harbor_acp_lane_test.rb"]
end

desc "The trend table over local artifacts/evals/runs, printed and written to its LEDGER.md (no boot)"
task :evals_ledger do
  require_relative "../support/evals/ledger"
  bench = evals_bench
  puts E2E::Evals::Ledger.write(bench.runs_dir, bench: bench)
end

# Paid batches inherit explicit opt-in; starting the batch never grants it to its children.
# Nexus worlds pin development by default, so a caller need not set RAILS_ENV themselves.
def validate_live_batch!
  require_relative "../support/manual_client"
  E2E::ManualClient.validate!(ENV.to_h.merge("RAILS_ENV" => ENV.fetch("RAILS_ENV", "development")))
end
private :validate_live_batch!

# THE THREE GRADED LANES AS ONE COMMAND, each a `bundle exec rake` child as the sweep runs them:
# the child's own task applies the lane's patience. One verdict line per lane in the sweep's
# shape; the ladder stops at the first FAIL (the Long lane is an hour and
# some dollars, and Medium red says the model is not ready for it).
LIVE_EXIT_LANES = %w[exit_small exit_medium exit_long].freeze

desc "Gate 3: the three graded lanes in order on E2E_LIVE_MODEL, one verdict line each " \
     "(paid, ≈ 1–1.5 h and ≈ $4–8 per model): E2E_LIVE=1"
task :live_exit do
  validate_live_batch!
  model = ENV.fetch("E2E_LIVE_MODEL") { evals_bench.tiers.fetch(E2E::Evals::Bench::FLOOR).fetch(0) }
  logs = File.join(Dir.pwd, "tmp", "live_exit")
  FileUtils.mkdir_p(logs)
  LIVE_EXIT_LANES.each do |lane|
    log = File.join(logs, "#{lane}.#{model.tr("/", "_")}.log")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # ONE file description for both streams: `out: log, err: log` opens the path twice at
    # independent offsets, and stderr's teardown dump then overwrites the report.
    ok = system({ "E2E_LIVE_MODEL" => model }, "bundle", "exec", "rake", "live_#{lane}", [:out, :err] => [log, "w"])
    seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
    puts format("%-24s %-40s %-5s %4ds  %s", lane, model, ok ? "pass" : "FAIL", seconds, ok ? "" : log)
    abort "live_exit: #{lane} failed on #{model} (its log is named above)" unless ok
  end
  puts "\nlive_exit: #{LIVE_EXIT_LANES.size} lanes passed on #{model}"
end

desc "A REAL model drives a real browser through rho's extension plane and " \
     "proves it by what it read off the page (paid, local): E2E_LIVE=1"
task :live_browser do
  run_e2e_tests("live_browser_test")
end

Minitest::TestTask.create(:live_browser_test) do |t|
  t.test_globs = ["test/live_browser_test.rb"]
end

desc "A REAL model reaches a public MCP server's tool (the filesystem server, npx-pinned) through " \
     "rho-mcp beside rho's own reads — the task names the file and the goal, never the tool; a native " \
     "read is the red finding (paid, local, ≈ $0.02–0.10): E2E_LIVE=1"
task :live_mcp do
  run_e2e_tests("live_mcp_test")
end

Minitest::TestTask.create(:live_mcp_test) do |t|
  t.test_globs = ["test/live_mcp_test.rb"]
end

desc "A REAL public OAuth MCP server: `rho mcp login` with the REAL browser " \
     "(you click consent within five minutes), the boot, `rho mcp` connected + logged in, one floor-model turn " \
     "whose task names the goal never the tool, pinned on completion and on token-freedom; the reach recorded, " \
     "not gated. MANUAL, once in the paid window (paid, local, ≈ $0.02–0.05): " \
     "E2E_LIVE=1 E2E_MCP_OAUTH_URL=<url> E2E_MCP_OAUTH_GOAL=\"<task>\" [E2E_MCP_OAUTH_CLIENT_ID=<id>]"
task :live_mcp_oauth do
  run_e2e_tests("live_mcp_oauth_test")
end

Minitest::TestTask.create(:live_mcp_oauth_test) do |t|
  t.test_globs = ["test/live_mcp_oauth_test.rb"]
end

desc "A REAL model reads a public page through rho-web-tools's web_fetch beside rho's own tools — the task " \
     "names the page and the goal, never the tool; a `curl` through bash is the red finding (paid, local, " \
     "≈ $0.01–0.05): E2E_LIVE=1"
task :live_web_fetch do
  run_e2e_tests("live_web_fetch_test")
end

Minitest::TestTask.create(:live_web_fetch_test) do |t|
  t.test_globs = ["test/live_web_fetch_test.rb"]
end

desc "The images rider's vision half: one browser_screenshot turn on the required E2E_VISION_MODEL, " \
     "the PNG placed as a part and the model answering about the page (paid, < $1): E2E_LIVE=1"
task :live_capture do
  run_e2e_tests("live_capture_test")
end

Minitest::TestTask.create(:live_capture_test) do |t|
  t.test_globs = ["test/live_capture_test.rb"]
end

desc "Two loops drive one browser at once on their own tabs (paid, local): E2E_LIVE=1"
task :live_two_loops_browser do
  run_e2e_tests("live_two_loops_browser_test")
end

Minitest::TestTask.create(:live_two_loops_browser_test) do |t|
  t.test_globs = ["test/live_two_loops_browser_test.rb"]
end

desc "say / pause / resume / stop a real conversation from the CLI (paid, local): E2E_LIVE=1"
task :live_intervention do
  run_e2e_tests("live_intervention_test")
end

Minitest::TestTask.create(:live_intervention_test) do |t|
  t.test_globs = ["test/live_intervention_test.rb"]
end

desc "AGENTS.md reaches a real model and the kernel refuses a force push by rho's guard list (paid, local): E2E_LIVE=1"
task :live_guard_and_conventions do
  run_e2e_tests("live_guard_and_conventions_test")
end

Minitest::TestTask.create(:live_guard_and_conventions_test) do |t|
  t.test_globs = ["test/live_guard_and_conventions_test.rb"]
end

desc "A real model under --approval ask: one command approved, the next denied with a reason, " \
     "and the model reformulates (paid, both weak models): E2E_LIVE=1"
task :live_approval do
  run_e2e_tests("live_approval_test")
end

Minitest::TestTask.create(:live_approval_test) do |t|
  t.test_globs = ["test/live_approval_test.rb"]
end

desc "A real model's words reach a terminal as it writes them, and the anchored lines " \
     "survive it (paid, both weak models): E2E_LIVE=1"
task :live_streaming do
  run_e2e_tests("live_streaming_test")
end

Minitest::TestTask.create(:live_streaming_test) do |t|
  t.test_globs = ["test/live_streaming_test.rb"]
end

# EVERY OPERATION, ON EVERY WEAK MODEL, AS ONE COMMAND. The owner's rule for a capability: fill the
# gap, then test it for real with the models that will actually drive it. One line per (journey,
# model) with its verdict; a failing journey's own output is in its log file. E2E_LIVE=1 rake
# live_sweep # every live journey, both models E2E_LIVE=1 rake live_sweep[until,processes] # a
# subset
# `vision` and `capture` require their own target (`E2E_VISION_MODEL`), never
# the sweep's floor rows — which read the index line and could not answer — so the sweep leaves them
# to their own tasks (the floor's half of the images rider rides `live_rho_runner`). `mcp_oauth` is
# MANUAL — a real consent click inside five minutes, and a server named by `E2E_MCP_OAUTH_URL` — so
# the sweep leaves it to its own task too: it must not block the sweep twice for five minutes.
# `acp_client` runs codex-acp under THIS MACHINE'S Codex login — the owner's quota, `npx`, not a
# floor row's — so the sweep leaves it to its own task; `acp_agent` reads the sweep's model and
# rides.
# The deferred-tools comparison owns one fixed-model campaign and one aggregate
# cost stop; repeating it for every sweep model would not compare those models.
LIVE_SWEEP_SKIP = %w[long_session vision capture mcp_oauth acp_client deferred_tools tool_discovery_smoke].freeze

desc "Run every live journey on every weak model and print one verdict per pair (paid): E2E_LIVE=1. " \
     "Since Gate 3 the glob also carries exit_medium (≈ 10 min), exit_long (≈ 40–60 min) and gallery " \
     "(≈ 30–40 min) at their own tasks' deadlines — ≈ 1.5–2 h more wall time per model; " \
     "live_sweep[exit_medium,exit_long,gallery] is that subset"
task :live_sweep, [:only] do |_t, args|
  validate_live_batch!
  models = ENV.fetch("E2E_SWEEP_MODELS") { evals_bench.tiers.fetch(E2E::Evals::Bench::FLOOR).join(",") }.split(",")
  journeys = Dir["test/live_*_test.rb"].map { |f| File.basename(f, "_test.rb").delete_prefix("live_") }.sort
  journeys -= LIVE_SWEEP_SKIP
  # rake splits `live_sweep[a,b,c]` into one named argument and extras.
  wanted = [args[:only], *args.extras].compact.flat_map { |v| v.split(",") }
  journeys &= wanted unless wanted.empty?
  logs = File.join(Dir.pwd, "tmp", "live_sweep")
  FileUtils.mkdir_p(logs)
  verdicts = []
  models.each do |model|
    journeys.each do |journey|
      log = File.join(logs, "#{journey}.#{model.tr("/", "_")}.log")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # One file description for both streams (the `live_exit` note).
      ok = system({ "E2E_LIVE_MODEL" => model },
        "bundle", "exec", "rake", "live_#{journey}", [:out, :err] => [log, "w"])
      seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
      verdicts << [journey, model, ok ? "pass" : "FAIL", seconds, log]
      puts format("%-24s %-40s %-5s %4ds  %s", journey, model, verdicts.last[2], seconds, ok ? "" : log)
    end
  end
  failed = verdicts.reject { |v| v[2] == "pass" }
  puts "\n#{verdicts.size} runs, #{failed.size} failed"
  abort "live sweep failed: #{failed.map { |v| "#{v[0]} on #{v[1]}" }.join(", ")}" unless failed.empty?
end

desc "What a console renders, read through the daemon: transcript, task, and the pushed event stream (paid): E2E_LIVE=1"
task :live_console_reads do
  run_e2e_tests("live_console_reads_test")
end

Minitest::TestTask.create(:live_console_reads_test) do |t|
  t.test_globs = ["test/live_console_reads_test.rb"]
end

desc "A conversation: `rho do` opens it, the next thing you say is its next turn, a steer lands " \
     "mid-turn, and a memory note written in one turn is read by the next (paid): E2E_LIVE=1"
task :live_conversation do
  run_e2e_tests("live_conversation_test")
end

Minitest::TestTask.create(:live_conversation_test) do |t|
  t.test_globs = ["test/live_conversation_test.rb"]
end

desc "A real VISION model reads a generated 24×24 red square staged through the member plane: turn 1 names " \
     "its colour, turn 2 (no attachment) its shape — only a picture carried in the history can answer (paid, " \
     "cents): E2E_LIVE=1; E2E_VISION_MODEL is required; out of the " \
     "graded exit lanes and the sweep"
task :live_vision do
  run_e2e_tests("live_vision_test")
end

Minitest::TestTask.create(:live_vision_test) do |t|
  t.test_globs = ["test/live_vision_test.rb"]
end

desc "Compare eager and deferred tools through real rho turns before and after adding a Runner (paid; " \
     "E2E_LIVE=1 DEEPSEEK_API_KEY; USD 2 aggregate soft stop; receipts and rebuilt requests in artifacts/deferred-tools)"
task :live_deferred_tools do
  require_relative "../support/deferred_tools_diagnostic"
  E2E::DeferredToolsDiagnostic.validate!(ENV.to_h.merge("RAILS_ENV" => ENV.fetch("RAILS_ENV", "development")))
  overrides = E2E::DeferredToolsDiagnostic.model_overrides(nexus_root: File.expand_path("../../nexus", __dir__))
  run_e2e_tests("live_deferred_tools_test", journey_seconds: 2400, model_overrides: overrides)
end

Minitest::TestTask.create(:live_deferred_tools_test) do |t|
  t.test_globs = ["test/live_deferred_tools_test.rb"]
end

desc "One eager-direct/deferred read on each reference model, then a floor-model coding pair (paid; " \
     "E2E_LIVE=1; USD 3 aggregate soft stop; no repeated samples)"
task :live_tool_discovery_smoke do
  require_relative "../support/tool_discovery_smoke"
  E2E::ToolDiscoverySmoke.validate!(ENV.to_h.merge("RAILS_ENV" => ENV.fetch("RAILS_ENV", "development")))
  run_e2e_tests("live_tool_discovery_smoke_test", journey_seconds: 5400,
    model_overrides: E2E::ToolDiscoverySmoke.model_overrides)
end

Minitest::TestTask.create(:live_tool_discovery_smoke_test) do |t|
  t.test_globs = ["test/live_tool_discovery_smoke_test.rb"]
end

desc "The 1-hour cache tier on the direct Anthropic key (pre-audit L437): two turns on anthropic/claude-sonnet-5 " \
     "through rho, the receipts' per-tier write share read the way settlement reads it — a 1-hour write on turn 1, " \
     "a read on turn 2 (paid, cents): E2E_LIVE=1 + ANTHROPIC_API_KEY; E2E_CACHE_TIER_MODEL names the row; out of " \
     "the graded exit lanes and the sweep"
task :live_cache_tier do
  run_e2e_tests("live_cache_tier_test")
end

Minitest::TestTask.create(:live_cache_tier_test) do |t|
  t.test_globs = ["test/live_cache_tier_test.rb"]
end

desc "rho as an ACP AGENT on the floor model: the scripted client drives `rho-acp --mode ask` — " \
     "a bash approved over the wire and run, and a `/skill-name` prompt's reach for the `skill` tool measured and " \
     "printed (paid, cents): E2E_LIVE=1; E2E_ACP_AGENT_MODEL names the row (else E2E_LIVE_MODEL); out of the graded lanes"
task :live_acp_agent do
  run_e2e_tests("live_acp_agent_test")
end

Minitest::TestTask.create(:live_acp_agent_test) do |t|
  t.test_globs = ["test/live_acp_agent_test.rb"]
end

desc "rho as an ACP CLIENT of codex-acp under THIS MACHINE'S Codex login: the floor " \
     "model delegates a two-file edit through delegate_agent; no `authenticate` sent, `_auth/status_update` kind " \
     "account, the thread's files deleted, JWTs and the account redacted, the capture kept under tmp/live_acp_client " \
     "(paid: the floor's cents and the login's Codex quota; local, `npx`): E2E_LIVE=1; E2E_ACP_CODEX_MODEL is required; SKIPS without " \
     "CODEX_HOME/auth.json (~/.codex); out of the sweep"
task :live_acp_client do
  run_e2e_tests("live_acp_client_test")
end

Minitest::TestTask.create(:live_acp_client_test) do |t|
  t.test_globs = ["test/live_acp_client_test.rb"]
end

desc "The index-line bench (paid, local, no boot): the line a text-only row reads for a picture, in each " \
     "spelling of E2E_BENCH_ROWS (index, codex, alt), E2E_BENCH_RUNS (10) times on the two floor rows and " \
     "one strong text-only row (E2E_BENCH_MODELS); one property — the model says it cannot see the picture " \
     "and never invents it; readout under E2E_BENCH_DIR (default artifacts/bench), merged across runs"
task :live_attachment_line do
  sh({ "RAILS_ENV" => "development" }, Gem.ruby, "-I.", "test/attachment_line_probe_test.rb")
end

desc "Re-score the recorded index-line readout under E2E_BENCH_DIR from its stored replies (no boot, no paid " \
     "call): captures re-stamp, never recapture — the example-aware scorer rewrites the json and the tables"
task :attachment_line_rescore do
  require_relative "../support/attachment_line_bench"
  before, after = E2E::AttachmentLineBench.rescore
  abort "attachment_line_rescore: no readout under #{E2E::AttachmentLineBench.bench_dir}" if before.empty?
  puts "before: #{E2E::AttachmentLineBench.passes(before).map { |row, n| "#{row} #{n}" }.join("  ")}"
  puts "after:  #{E2E::AttachmentLineBench.passes(after).map { |row, n| "#{row} #{n}" }.join("  ")}"
  puts "#{after.size} cell(s) re-scored under #{E2E::AttachmentLineBench.bench_dir}"
end

desc "A memory note `rho do` saves under user/ is read by a member-plane conversation in a SECOND " \
     "workspace of the same person — the block carried it across workspaces (paid): E2E_LIVE=1"
task :live_memory_scopes do
  run_e2e_tests("live_memory_scopes_test")
end

Minitest::TestTask.create(:live_memory_scopes_test) do |t|
  t.test_globs = ["test/live_memory_scopes_test.rb"]
end

desc "A loop that halts, repaired from the terminal with abandon and retry (paid): E2E_LIVE=1"
task :live_repair do
  run_e2e_tests("live_repair_test")
end

Minitest::TestTask.create(:live_repair_test) do |t|
  t.test_globs = ["test/live_repair_test.rb"]
end

desc "rho do --until: a failing check hands the model the output; a passing one closes the loop (paid): E2E_LIVE=1"
task :live_until do
  run_e2e_tests("live_until_test")
end

Minitest::TestTask.create(:live_until_test) do |t|
  t.test_globs = ["test/live_until_test.rb"]
end

desc "A mid-conversation `rho handoff` from rho's own runner to a runner-mode rho on a second home over " \
     "the same tree; the next turn's bash runs there — its log the proof (paid): E2E_LIVE=1"
task :live_handoff do
  run_e2e_tests("live_handoff_test")
end

Minitest::TestTask.create(:live_handoff_test) do |t|
  t.test_globs = ["test/live_handoff_test.rb"]
end

desc "An agent-mode rho names a runner-mode rho by `rho do --runner` and a real model does a " \
     "coding turn on it (paid): E2E_LIVE=1"
task :live_rho_runner do
  run_e2e_tests("live_rho_runner_test")
end

Minitest::TestTask.create(:live_rho_runner_test) do |t|
  t.test_globs = ["test/live_rho_runner_test.rb"]
end

desc "A model starts a dev server; the person lists, reads and kills it (paid): E2E_LIVE=1"
task :live_processes do
  run_e2e_tests("live_processes_test")
end

Minitest::TestTask.create(:live_processes_test) do |t|
  t.test_globs = ["test/live_processes_test.rb"]
end

desc "A session long enough to overflow its context: compaction arms and the work survives (paid, long): " \
     "E2E_LIVE=1 E2E_JOURNEY_SECONDS=5400 E2E_TEARDOWN_DEADLINE_SECONDS=600 (a hundred rounds leave databases that take a while to drop); " \
     "E2E_COMPACTION=delegate runs every wall through rho's own summarizer instead of the kernel's"
task :live_long_session do
  run_e2e_tests("live_long_session_test", journey_seconds: 5400, teardown_seconds: 600)
end

Minitest::TestTask.create(:live_long_session_test) do |t|
  t.test_globs = ["test/live_long_session_test.rb"]
end

desc "One streamed OpenAI reply printed as compact diagnostics (paid, local): " \
     "E2E_LIVE=1 OPENAI_API_KEY [E2E_LIVE_MODEL]"
task :live do
  sh({ "RAILS_ENV" => "development" }, Gem.ruby, "-I.", "test/manual_provider_smoke_test.rb")
end

desc "Small OpenRouter chat/tool/reasoning and vision diagnostics (paid, no Nexus boot): " \
     "RAILS_ENV=development E2E_LIVE=1 OPENROUTER_API_KEY E2E_OPENROUTER_CHAT_MODELS/_TOOL_MODELS/_VISION_MODELS"
task :live_openrouter do
  sh(Gem.ruby, "-I.", "manual/openrouter_smoke.rb")
end

desc "Prove prompt-cache economics against real Anthropic (paid, local; E2E_LIVE=1 + ANTHROPIC_API_KEY, else skipped): " \
     "a 3-round tool loop on a thinking model over direct api.anthropic.com through the kernel's own placement — " \
     "round one writes the prefix, every round from two on reads the prior round's whole prompt (the cache audit's step 7)"
task :live_prompt_cache do
  sh({ "RAILS_ENV" => "development" }, Gem.ruby, "-I.", "test/prompt_cache_probe_test.rb")
end


desc "The tools' lane, offline half (paid, local): gate 0, the background suite and the " \
     "over-reach control on both weak models, against the set a rho turn declares under each " \
     "task/ask spelling (E2E_BENCH_STYLES=nexus,claude,codex; the baseline by default)"
task :live_task_probe do
  sh({ "RAILS_ENV" => "development" }, Gem.ruby, "-I.", "test/task_matrix_probe_test.rb")
end

desc "The tools' lane, cross-turn half through exe/rho (paid): a background task's result arrives as " \
     "mail in the next turn, and the blocking fan of five (both weak models × E2E_TASK_RUNS): E2E_LIVE=1 " \
     "E2E_DEADLINE_SECONDS=5400 E2E_TEARDOWN_DEADLINE_SECONDS=600"
task :live_task_mail do
  run_e2e_tests("live_task_mail_test")
end

Minitest::TestTask.create(:live_task_mail_test) do |t|
  t.test_globs = ["test/live_task_mail_test.rb"]
end

desc "The whole tools' lane (paid): the offline half, then the cross-turn half"
task live_task_matrix: %i[live_task_probe live_task_mail]

desc "rho Side beside a running turn on a real model: inherited context, a stable snapshot, " \
     "and provider cache observations (paid; run ALONE): E2E_LIVE=1"
task :live_side do
  run_e2e_tests("live_side_test")
end

Minitest::TestTask.create(:live_side_test) do |t|
  t.test_globs = ["test/live_side_test.rb"]
end

desc "spawn on a real model through exe/rho (paid; both floor models; run ALONE): the SUBAGENT variant " \
     "— a detached child's reply is `origin: child` mail, turn 2 names the failing test from it — and the PEER " \
     "variant under the room knob — a second rho home in the steward's room, `to: @handle`, `wait: true`, every " \
     "claim on home A's runner: E2E_LIVE=1 E2E_DEADLINE_SECONDS=3600 E2E_TEARDOWN_DEADLINE_SECONDS=300; " \
     "E2E_SPAWN_MODELS / E2E_SPAWN_VARIANTS=subagent,peer narrow the matrix"
task :live_spawn do
  run_e2e_tests("live_spawn_test", journey_seconds: 3300, teardown_seconds: 300)
end

Minitest::TestTask.create(:live_spawn_test) do |t|
  t.test_globs = ["test/live_spawn_test.rb"]
end

# Paid smoke journeys for the tracker document, persistent approval grant, scheduled input and
# file-defined agent. Each drives the user-facing CLI against the selected floor model.
desc "A real model keeps the conversation's checklist through a multi-step task: conversation/todo.md through " \
     "the member door, the block on rho watch (paid; the floor): E2E_LIVE=1"
task :live_todo do
  run_e2e_tests("live_todo_test")
end

Minitest::TestTask.create(:live_todo_test) do |t|
  t.test_globs = ["test/live_todo_test.rb"]
end

desc "rho approve --always on a real model's first park under ask; the next ask turn's same call never parks " \
     "and rho rules lists the grant (paid; the floor): E2E_LIVE=1"
task :live_grant do
  run_e2e_tests("live_grant_test")
end

Minitest::TestTask.create(:live_grant_test) do |t|
  t.test_globs = ["test/live_grant_test.rb"]
end

desc "rho say --in 15s on a real conversation: the turn opens not before its time and completes after it " \
     "(paid; the floor): E2E_LIVE=1"
task :live_deliver_at do
  run_e2e_tests("live_deliver_at_test")
end

Minitest::TestTask.create(:live_deliver_at_test) do |t|
  t.test_globs = ["test/live_deliver_at_test.rb"]
end

desc "A .agents/agents/reviewer.md at the project root, rho agents sync, and a real model's spawn by name: " \
     "the child's answerer is the reviewer's row and its turn ran (paid; the floor): E2E_LIVE=1"
task :live_named_agent do
  run_e2e_tests("live_named_agent_test")
end

Minitest::TestTask.create(:live_named_agent_test) do |t|
  t.test_globs = ["test/live_named_agent_test.rb"]
end
