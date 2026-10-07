require "test_helper"
require "support/live_journey"
require "support/evals"
require "support/evals/harbor_acp"

# THE HARBOR CELL'S LANE: the benchmark door run the way every paid lane runs — the world booted by
# the Rakefile (`run_e2e_tests` → `E2E::NexusServer`, `rake "evals_harbor_acp[run]"`), the steward
# signed in, the account priced, the cell's provider enabled and the hosts started
# (`LiveJourney#price_and_open_lane!`: the same steps `evals/lane_test.rb` takes for a
# terminal-bench cell, less the daemon of its own — this lane's daemons live inside harbor's task
# containers and pair through the sidecar) — then `HarborAcp.run!` with THIS lane's steward as the
# confirm, and the trials imported. Outside test/ like `lane_test.rb`: the journey manifest scans
# test/ alone. One case; the plan is built in `setup`, never at load — the corpus is
# E2E_EVALS_TB_CORPUS's, absent on a syntax check.
#
# WHY A LANE AND NOT THE RAKE TASK ALONE: `[run]` used to call `run!`
# against an E2E_BASE_URL nobody had booted; the harness boots its worlds
# inside a Minitest lane, and pricing and the provider are the lane's
# steps, never the world's.
#
# THE ADDRESS HARBOR'S CONTAINERS REACH: the box runs harbor's task
# containers on harbor's own compose bridge — never the plain driver's
# `--network host` — so the world's 127.0.0.1 is the container itself
# there; the box's LAN IP under the world's port
# (E2E_EVALS_HARBOR_NEXUS_HOST=10.0.0.115) is the address, and the world
# binds 0.0.0.0 for it (E2E_NEXUS_BIND, `support/nexus_server.rb`). The
# cell's `nexus_url` comes from the BOOTED world (`Cell#with_world`),
# never from the environment at plan time.
#
# Paid, local, opt-in: E2E_LIVE=1 and the floor's provider key;
# E2E_EVALS_TASKS / _MODELS / _RUNS / _LABEL narrow the cell,
# E2E_EVALS_HARBOR_JOBS_DIR places harbor's job dir.
class HarborAcpLaneTest < Minitest::Test
  include E2E::LiveJourney

  LOG_TAIL_LINES = 40

  def setup
    @bench = E2E::Evals::Bench.read
    @cell = E2E::Evals::HarborAcp::Cell.plan(bench: @bench, env: ENV)
    start_live_journey!(@cell.model, home_prefix: "rho-evals-harbor-e2e")
  end

  def teardown = finish_live_journey!

  # The lane's lines are its records' (`ReportLine`), never a per-loop
  # teardown line: no loop of this process's was awaited.
  def reports_own_lines? = true

  def test_the_harbor_cell_pairs_through_this_lanes_steward_and_lands_one_record_per_trial
    price_and_open_lane!
    cell = @cell.with_world(@base_url, env: ENV)
    puts "\n=== harbor acp: #{cell.tasks.size} task(s) × k=#{cell.runs} on #{cell.model}; " \
         "nexus for the containers: #{cell.nexus_url} (#{cell.nexus_url_source})"
    outcome = E2E::Evals::HarborAcp.run!(cell, base_url: @base_url, confirm: steward_confirm)
    outcome.records.each { |record| puts E2E::Evals::ReportLine.render(record) }
    puts "#{outcome.records.size} record(s) under #{cell.run_dir}; then: rake evals_ledger"
    flunk "harbor exited #{outcome.status.exitstatus.inspect} (paired #{outcome.paired.size} container(s)); " \
          "the tail of #{cell.log_path}:\n#{log_tail(cell.log_path)}" unless outcome.status.success?
    assert_records_written!(cell, outcome.records)
  end

  private

    # The lane's steward as the sidecar's confirm: the memoised signed-in
    # browser (`StewardSession`, `start_live_journey!`), the document at
    # its own origin (`HarborAcp.pairing_for_steward`), no daemon status
    # to await — the launcher inside the container awaits the adoption.
    def steward_confirm = ->(started) { E2E::Ceremony.confirm(actor: @actor, started: started, status: nil) }

    # EVERY TRIAL LEAVES A RECORD, never that every record is green (the
    # plain lane's rule): one per (task × 1..k) in the ledger's key, each
    # on disk under the cell's run dir in the cell's own row shape — the
    # family's, `driver: harbor-acp`, style `acp`, no reach dimension, a
    # verdict on `task_pass` alone — and the ledger lists the cell's row
    # for every task.
    def assert_records_written!(cell, records)
      expected = cell.tasks.flat_map { |task| (1..cell.runs).map { |run| [task.name, cell.model, "acp", run] } }
      keys = records.map { |record| E2E::Evals::Records.key(record) }
      # As a multiset: `import` orders by task name, the bench by its list.
      assert_equal expected.sort, keys.sort, "every trial leaves a record"
      assert_empty keys - E2E::Evals::Records.read(cell.run_dir).map { |record| E2E::Evals::Records.key(record) },
        "the records are on disk under #{cell.run_dir}"
      records.each do |record|
        assert_equal [E2E::Evals::HarborAcp::FAMILY, E2E::Evals::HarborAcp::DRIVER, E2E::Evals::HarborAcp::STYLE, @bench.digest],
          record.values_at("family", "driver", "style", "bench_digest")
        assert_equal [nil, nil], record.fetch("verdict").values_at("reached", "succeeded"), "no reach dimension"
        assert_includes [true, false], record.dig("verdict", "task_pass")
        assert_path_exists record.fetch("artifact"), "the trial's events file is the record's artifact"
      end
      ledger = E2E::Evals::Ledger.render(@bench.runs_dir, bench: @bench)
      floor = E2E::Evals::Bench::FLOOR
      model = "#{cell.model}#{@bench.tier_of(cell.model) == floor ? " (#{floor}, read-only)" : ""}"
      cell.tasks.each do |task|
        assert_includes ledger, "| #{E2E::Evals::HarborAcp::FAMILY} | #{task.name} | #{model} | #{E2E::Evals::HarborAcp::STYLE} |",
          "the ledger lists the cell's row for #{task.name}"
      end
    end

    def log_tail(path)
      return "(no #{File.basename(path)})" unless File.file?(path)

      E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join)
    end
end
