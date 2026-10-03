$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "bigdecimal"
require "digest"
require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "yaml"
require "support/screen/analysis"
require "support/screen/definition"

# THE ANALYSIS ENGINE, over a synthetic pair laid out as a screen's jobs — a real `Definition` whose
# job table names, per arm and model, one job on O1 and O3 and one on O7b: the registered shape is
# the stamp's job table (each job's own objectives and samples), the batch is refused whole on a
# duplicate, an early record, a harness fault, a moved tree or a missing stamp; lost draws over the
# stamp's registered floor name the relaunch class and decide nothing; a kernel finding
# short-circuits every clause; a stopped batch writes its stop in place of a verdict; the machine
# lines carry the verdict and both shas; the cost is the pricer's. The screen's clauses here are a
# FAKE set — the engine reads any set that answers the protocol.
class ScreenAnalysisHarnessTest < Minitest::Test
  A = E2E::Screen::Analysis
  R = E2E::Screen::Records
  Clause = E2E::Screen::Clause
  Figure = E2E::Screen::Figure
  PAIR = File.expand_path("../support/fixtures/screen/pairs/compose-reads", __dir__)
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)
  MODELS = %w[fake/chat-a fake/chat-b].freeze
  LAUNCHED_AT = "2026-09-26T23:00:00Z".freeze

  # A FAKE clause set: E1 is the compose right share of `with` against `without`, landing when its
  # lower bound clears +5; the figure is E1's at the registered n from the pair's base rates, at a
  # change of +10 points, which the base arm's rate leaves room for.
  FakeSet = Data.define(:finding) do
    def kernel_finding(_draws) = finding

    def clauses(draws)
      right = ->(draw) { draw["first_time_right"] == true && draw["opaque"] != true }
      [Clause.contrast(name: "E1", arm: "with", against: "without", test: right, rule: "lower > +5",
        arm_draws: R.select(draws, arm: "with", instrument: "compose"),
        base_draws: R.select(draws, arm: "without", instrument: "compose")) { |clause| clause.contrast.lower > 5.0 }]
    end

    def verdict(clauses)
      landed = clauses.all?(&:holds)
      E2E::Screen::Analysis::Verdict.new(name: landed ? "LAND" : "NOT-LANDED", text: landed ? "E1 holds" : "E1 does not hold")
    end

    def reads(draws) = ["opaque: #{draws.count { |draw| draw["opaque"] == true }}"]

    def figures(draws, jobs)
      cells = jobs.select { |job| job.arm == "without" }.flat_map do |job|
        job.objectives.map do |objective|
          cell = R.select(draws, arm: "without", models: [job.model], objectives: [objective])
          [job.n, cell.count { |draw| draw["first_time_right"] == true }.fdiv(cell.length)]
        end
      end
      [Figure.of(key: "E1", name: "E1 (lower > +5)", cells: cells, shift: 10.0) { |contrast| contrast.lower > 5.0 }]
    end

    def stops(figures) = figures.select { |figure| figure.zero > 0.03 }.map { |figure| "#{figure.key} lands a zero-effect change" }
  end

  PRICE = ->(draw) { BigDecimal("0.001") * R.calls(draw) }

  def setup
    @root = Dir.mktmpdir("screen-analysis")
    @home = File.join(@root, "home")
    @trees = %w[with without].to_h { |tree| [tree, git_tree(File.join(@root, tree))] }
  end

  def teardown = FileUtils.remove_entry(@root)

  # THE REGISTERED SHAPE IS THE JOB TABLE: a job may name two objectives and another the third; the
  # analysis reads exactly those cells, decides, and writes its verdict with the machine lines.
  def test_the_job_table_is_the_registered_shape_and_the_analysis_writes_its_verdict_and_machine_lines
    definition = lay_out
    path = A.run(definition, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)
    assert_equal File.join(@home, "analysis.md"), path
    text = File.read(path, encoding: "UTF-8")
    assert_includes text, File.read(File.join(@home, "stamp.txt"), encoding: "UTF-8").strip, "the stamp is the header"
    assert_match(/E1 with: \d+\/18 .* against without \d+\/18/, text)
    assert_includes text, "opaque: "
    machine = A.machine_lines(path)
    assert_includes %w[LAND NOT-LANDED], machine.fetch("verdict")
    assert_equal "none", machine.fetch("relaunch")
    assert_equal definition.sha256, machine.fetch("definition_sha256")
    assert_equal Digest::SHA256.file(File.join(@home, "stamp.txt")).hexdigest, machine.fetch("stamp_sha256")
    assert_equal %w[definition_sha256 relaunch stamp_sha256 verdict], machine.keys.sort, "the section's own lines, never the stamp's"
  end

  # THE COST IS THE PRICER'S (BenchSpend's in a launch): every draw priced whole, first and repair
  # calls alike, summed per (model, arm).
  def test_the_cost_table_is_the_pricers
    definition = lay_out
    text = File.read(A.run(definition, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new),
      encoding: "UTF-8")
    draws = R.select(R.pair(PAIR), arm: "without", models: [MODELS.last])
    total = draws.sum { |draw| PRICE.call(draw) }
    assert_equal 10, draws.sum { |draw| R.calls(draw) }, "nine draws, one of them repaired"
    assert_includes text, "| fake/chat-b | without | 9 | 10 | 50000 | 8000 | 0 | 0 | $#{total.round(4).to_s("F")} |"
  end

  def test_a_missing_cell_refuses_and_so_does_a_draw_beyond_the_table
    definition = lay_out
    drop(records_of(definition, "without", MODELS.last, "O7b")) { |record| record["sample"] == 2 }
    refused = refusal(definition)
    assert_match(/not the registered batch: 1 missing \(without compose fake\/chat-b O7b nexus 2\)/, refused)

    definition = lay_out
    narrowed = definition.with(cells: definition.cells.map { |cell| cell.with(n: 2) })
    assert_match(/0 missing .* 12 beyond it/, refusal(definition, stamp: stamp(narrowed)))
  end

  # THE STAMP'S TABLE, NOT THE DEFINITION'S: a relaunch after a storm stamps its merged layout, and a
  # later re-read under the definition's own table reads the batch the stamp registered.
  def test_the_stamps_job_table_is_read_whatever_the_definition_lays_out_now
    definition = lay_out
    split = definition.with(cells: definition.cells.map { |cell| cell.with(n: 4, split: 2) })
    refute_equal definition.jobs, split.jobs
    path = A.run(split, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)
    assert_equal "none", A.machine_lines(path).fetch("relaunch")
  end

  def test_a_duplicate_draw_a_record_before_the_launch_and_a_harness_fault_refuse
    definition = lay_out
    path = records_of(definition, "with", MODELS.first, "O1")
    File.write(path, File.readlines(path).first, mode: "a")
    assert_match(/1 draw\(s\) read twice: with compose fake\/chat-a O1 nexus 1/, refusal(definition))

    definition = lay_out
    assert_match(/recorded before launched_at/, refusal(definition, stamp: stamp(definition).merge("launched_at" => "2026-09-27T01:00:00Z")))

    definition = lay_out
    rewrite(records_of(definition, "without", MODELS.first, "O1")) do |record|
      record["sample"] == 1 && record["objective"] == "O1" ? record.merge("error" => "NoMethodError: undefined method 'x'") : record
    end
    assert_match(/a harness fault, not a draw: without compose fake\/chat-a O1 #1 NoMethodError/, refusal(definition))
  end

  # LOST OVER THE FLOOR IS A RELAUNCH CLASS, NEVER A VERDICT: more than 5 % AND at least three of a
  # (model, arm)'s draws, pooled over the instruments — two lost compose draws and one task draw
  # whose SECOND message failed make three of fifteen.
  def test_lost_draws_over_the_floor_name_the_relaunch_and_decide_nothing
    definition = lay_out(task: true)
    lose(records_of(definition, "with", MODELS.first, "O1"), 2)
    path = A.run(definition, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)
    text = File.read(path, encoding: "UTF-8")
    machine = A.machine_lines(path)
    assert_equal "RELAUNCH", machine.fetch("verdict")
    assert_equal "lost fake/chat-a/with 3/15", machine.fetch("relaunch")
    refute_match(/E1 with:/, text, "no clause is read on a batch owed a relaunch")
  end

  def test_two_lost_draws_are_under_the_floor_whatever_their_share
    definition = lay_out
    lose(records_of(definition, "with", MODELS.first, "O1"), 2)
    path = A.run(definition, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)
    text = File.read(path, encoding: "UTF-8")
    assert_equal "none", A.machine_lines(path).fetch("relaunch")
    assert_match(/E1 with:/, text)
  end

  # THE FLOOR IS THE STAMP'S: the watch's registered `lost_min_draws` and `lost_share`, the one pair
  # the watch's LOST stop reads too — a screen that registers a floor of two relaunches on two.
  def test_the_lost_floor_is_the_one_the_stamp_registered
    definition = lay_out
    lose(records_of(definition, "with", MODELS.first, "O1"), 2)
    path = A.run(definition, @home, stamp: stamp(definition).merge("watch.lost_min_draws" => "2.0"), clauses: FakeSet.new(finding: []),
      price: PRICE, out: StringIO.new)
    assert_equal ["RELAUNCH", "lost fake/chat-a/with 2/9"], A.machine_lines(path).values_at("verdict", "relaunch")
    assert_includes File.read(path, encoding: "UTF-8"), "(more than 5 % and at least 2 of a (model, arm))"
  end

  # A STOPPED BATCH DECIDES NOTHING: the stop the watch or the launch recorded is the analysis, over
  # whatever draws landed (a job that never drew is no refusal), and its class is the relaunch the
  # machine lines owe; a stop by hand that named no fault reads NOT-LANDED and owes none.
  def test_a_stopped_batch_writes_its_stop_in_place_of_a_verdict
    definition = lay_out
    FileUtils.rm_rf(File.dirname(records_of(definition, "without", MODELS.last, "O7b")))
    FileUtils.mkdir_p(File.join(@home, "logs"))
    File.write(E2E::Screen::Stop.path(@home), "2026-09-27T00:10:00Z SPEND $35.56 ≥ $25.00\n")
    path = A.run(definition, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)
    text = File.read(path, encoding: "UTF-8")
    assert_equal %w[STOPPED SPEND], A.machine_lines(path).values_at("verdict", "relaunch")
    assert_includes text, "## STOPPED — SPEND $35.56 ≥ $25.00"
    refute_match(/E1 with:/, text, "no clause is read on a stopped batch")
    assert_includes text, "| fake/chat-a | with | 9 |", "the draws that landed are costed"

    File.write(E2E::Screen::Stop.path(@home), "2026-09-27T00:10:00Z #{E2E::Screen::WatchRules.hand_stop("looks wrong")}\n")
    path = A.run(definition, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)
    assert_equal %w[NOT-LANDED none], A.machine_lines(path).values_at("verdict", "relaunch")
    refute_match(/E1 with:/, File.read(path, encoding: "UTF-8"))
  end

  # A task draw is lost when ANY of its messages ended in an error (the scored message may be the
  # second); the record carries the failing message's error. Only a failed call — the gem's own
  # error class — is lost: whatever else the harness raised, a scorer's KeyError included, is a
  # fault that refuses the batch.
  def test_a_task_draw_is_lost_when_any_message_failed
    ran = { "instrument" => "task", "messages" => [{ "index" => 1 }, { "index" => 2 }] }
    refute R.lost?(ran)
    assert R.lost?(ran.merge("error" => "SimpleInference::TimeoutError: execution expired"))
    assert R.lost?(ran.merge("messages" => [{ "index" => 1 }, { "index" => 2, "error" => "SimpleInference::ConnectionError: reset" }]))
    refute R.fault?(ran.merge("error" => "SimpleInference::HTTPError: 529 overloaded"))
    ["NoMethodError: undefined method 'x'", 'KeyError: key not found: "key"', "FrozenError: can't modify frozen Hash"].each do |error|
      refute R.lost?(ran.merge("error" => error)), "#{error}: a harness fault is refused, never lost"
      assert R.fault?(ran.merge("error" => error)), error
      refute R.lost?({ "instrument" => "compose", "reached" => false, "error" => error }), "#{error}: raised while scoring a compose draw"
      assert R.fault?({ "instrument" => "compose", "reached" => false, "error" => error }), error
    end
    refute R.lost?({ "instrument" => "compose", "reached" => true, "repaired" => "no_second_call", "repaired_error" => "SimpleInference::TimeoutError: x" }),
      "a compose draw whose repair failed still reached the model"
  end

  def test_a_kernel_finding_short_circuits_every_clause
    definition = lay_out
    path = A.run(definition, @home, stamp: stamp(definition), clauses: FakeSet.new(finding: ["replay mismatch on with model-a O1 #1"]), price: PRICE,
      out: StringIO.new)
    text = File.read(path, encoding: "UTF-8")
    machine = A.machine_lines(path)
    assert_equal "KERNEL-FINDING", machine.fetch("verdict")
    assert_equal "kernel-finding", machine.fetch("relaunch")
    assert_includes text, "replay mismatch on with model-a O1 #1"
    refute_match(/E1 with:/, text)
  end

  def test_a_missing_stamp_another_definition_or_a_moved_tree_refuses
    definition = lay_out
    launched = stamp(definition)
    File.delete(File.join(@home, "stamp.txt"))
    out = StringIO.new
    assert_nil A.run(definition, @home, clauses: FakeSet.new(finding: []), price: PRICE, out: out)
    assert_match(/no stamp/, out.string)

    File.write(File.join(@home, "stamp.txt"), "launched_at=#{LAUNCHED_AT}\n")
    assert_match(/another definition/, refusal(definition, stamp: launched.merge("definition_sha256" => "0" * 64)))
    assert_match(/no tree.without.root line/, refusal(definition, stamp: launched.except("tree.without.root")))

    # The readout directory is written after the draws, under the local artifacts tree: never a move.
    readout = File.join(@trees["with"], "e2e", "artifacts", "screen-readouts", "screen")
    FileUtils.mkdir_p(readout)
    File.write(File.join(readout, "analysis.md"), "x")
    refute_nil A.run(definition, @home, stamp: launched, clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)

    File.write(File.join(@trees["with"], "e2e", "probe.rb"), "changed")
    assert_match(/the with tree moved/, refusal(definition, stamp: launched))
    system("git", "-C", @trees["with"], "checkout", "-q", "--", "e2e/probe.rb", exception: true)
    # The SDK gem the e2e bundle loads by path runs in every draw as much as the kernel does.
    File.write(File.join(@trees["with"], "sdks", "ruby", "lib", "cybros_agent.rb"), "changed")
    assert_match(/the with tree moved since the launch: .*uncommitted: M sdks\/ruby\/lib\/cybros_agent.rb/, refusal(definition, stamp: launched))
    system("git", "-C", @trees["with"], "checkout", "-q", "--", "sdks/ruby/lib/cybros_agent.rb", exception: true)
    refute_nil A.run(definition, @home, stamp: launched, clauses: FakeSet.new(finding: []), price: PRICE, out: StringIO.new)
    commit(@trees["without"], "nexus/kernel.rb", "moved")
    assert_match(/the without tree moved/, refusal(definition, stamp: launched))
  end

  # A SCREEN'S CLAUSES are its definition's `clauses.rb`, read as a module body.
  def test_a_definitions_clauses_file_is_read_as_a_module_body
    dir = File.join(@root, "screen")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "clauses.rb"), <<~RUBY)
      extend self
      MARGIN = 5.0
      def kernel_finding(_draws) = []
      def margin = MARGIN
    RUBY
    set = A.clauses_of(dir)
    assert_empty set.kernel_finding([])
    assert_equal 5.0, set.margin
    refute defined?(::MARGIN), "the file's constants stay in its own module"
  end

  # A DRY RUN runs every clause's mechanics over the pair, computes the figures at the registered n
  # and names the stops; it reads no stamp and decides nothing.
  def test_a_dry_run_reads_the_pair_computes_the_figures_and_names_the_stops
    definition = definition(n: 8)
    figures = A.dry(definition, PAIR, clauses: FakeSet.new(finding: []))
    assert_equal 1, figures.clauses.length
    assert_equal 18, figures.clauses.first.n1, "the pair's draws of the arm"
    figure = figures.figures.first
    assert_equal 48, figure.n, "the registered n: two models × three objectives × 8"
    assert_operator figure.zero, :<, figure.at
    assert_equal figure.zero > 0.03, figures.stop?
    assert(figures.lines.any? { |line| line.start_with?("dry: E1 with:") })
    assert_includes figures.stamp_lines.last, "sim.stops="
  end

  # A pair with a harness fault is no pair, and neither is a directory holding no records: the dry
  # run refuses both before any clause is read.
  def test_a_dry_run_refuses_a_pair_with_a_harness_fault_or_no_records
    definition = definition(n: 8)
    pair = File.join(@root, "pair")
    FileUtils.cp_r(PAIR, pair)
    rewrite(File.join(pair, "compose", "without", R::FILE)) do |record|
      faulted = record.values_at("model", "objective", "sample") == [MODELS.first, "O1", 1]
      faulted ? record.merge("error" => "KeyError: key not found: \"key\"") : record
    end
    refused = assert_raises(E2E::Screen::Refused) { A.dry(definition, pair, clauses: FakeSet.new(finding: [])) }
    assert_match(/a harness fault in the pair: without compose #{Regexp.escape(MODELS.first)} O1 #1/, refused.message)

    empty = File.join(@root, "empty")
    FileUtils.mkdir_p(File.join(empty, "compose"))
    refused = assert_raises(E2E::Screen::Refused) { A.dry(definition, empty, clauses: FakeSet.new(finding: [])) }
    assert_equal "no records under #{empty}", refused.message
  end

  private

    # A real definition over the pair's two arms and two models: per (arm, model) one job on O1 and
    # O3 and one on O7b at `n`; with `task`, a task cell on the first model's T5 and G0 beside them.
    def definition(n:, task: false)
      dir = File.join(@root, "definition")
      FileUtils.mkdir_p(dir)
      compose = [%w[O1 O3], %w[O7b]].map { |objectives| { "instrument" => "compose", "models" => MODELS.dup, "objectives" => objectives, "n" => n } }
      tasks = task ? [{ "instrument" => "task", "models" => [MODELS.first], "objectives" => %w[T5 G0], "n" => 3 }] : []
      yaml = YAML.safe_load_file(File.join(FAKE, "screen.yml")).merge(
        "arms" => [{ "id" => "without", "tree" => "without", "row" => "R-WO", "base" => true }, { "id" => "with", "tree" => "with", "row" => "R-MIN" }],
        "cells" => compose + tasks
      )
      File.write(File.join(dir, "screen.yml"), YAML.dump(yaml))
      E2E::Screen::Definition.load(dir)
    end

    # The pair's records laid out as the definition's jobs, each job's own draws in its directory, and
    # the launch's stamp over them.
    def lay_out(task: false)
      FileUtils.rm_rf(@home)
      definition = definition(n: 3, task: task)
      draws = R.pair(PAIR)
      definition.jobs.each do |job|
        FileUtils.mkdir_p(job.path(@home))
        if job.instrument == "task"
          write_task_draws(job)
        else
          own = draws.select { |draw| draw.values_at("arm", "model") == [job.arm, job.model] && job.objectives.include?(draw["objective"]) }
          File.write(File.join(job.path(@home), R::FILE), own.map { |draw| "#{JSON.generate(draw.except("instrument"))}\n" }.join)
        end
      end
      File.write(File.join(@home, "stamp.txt"), stamp(definition).map { |key, value| "#{key}=#{value}\n" }.join)
      definition
    end

    # The records file of the compose job drawing `objective` for (arm, model).
    def records_of(definition, arm, model, objective)
      job = definition.jobs.find do |candidate|
        [candidate.arm, candidate.instrument, candidate.model] == [arm, "compose", model] && candidate.objectives.include?(objective)
      end
      File.join(job.path(@home), R::FILE)
    end

    # Task draws in the record stream's shape, the second draw's second message failed.
    def write_task_draws(job)
      draws = job.objectives.product(job.samples).map do |objective, sample|
        failed = objective == "T5" && sample == 2
        { "objective" => objective, "model" => job.model, "style" => job.style, "sample" => sample, "arm" => job.arm,
          "process" => job.index.to_s, "recorded_at" => "2026-09-27T00:00:00Z", "pid" => 1, "pass" => !failed,
          "messages" => [{ "index" => 1, "usage" => { "input_tokens" => 900, "output_tokens" => 40 } },
                         { "index" => 2, "usage" => { "input_tokens" => 1_200, "output_tokens" => 60 } }] }
          .merge(failed ? { "error" => "SimpleInference::TimeoutError: execution expired" } : {})
      end
      File.write(File.join(job.path(@home), R::FILE), draws.map { |draw| "#{JSON.generate(draw)}\n" }.join)
    end

    # The launch's stamp as Stage 0 writes it: the definition's sha, the watch's parameters, the job
    # table, and each tree's root, HEAD and state.
    def stamp(definition)
      { "launched_at" => LAUNCHED_AT, "definition_sha256" => definition.sha256 }
        .merge(definition.watch_params.lines.to_h { |line| line.split("=", 2) })
        .merge(definition.jobs.to_h { |job| ["job.#{job.index}", job.stamp_line] })
        .merge(*@trees.map { |tag, root| { "tree.#{tag}.root" => root, "head.#{tag}" => head(root), "tree.#{tag}.state" => E2E::Screen::Watch.tree_state(root) } })
    end

    def refusal(definition, stamp: stamp(definition))
      out = StringIO.new
      assert_nil A.run(definition, @home, stamp: stamp, clauses: FakeSet.new(finding: []), price: PRICE, out: out)
      out.string
    end

    def rewrite(path, &change)
      records = R.read(path).map(&change)
      File.write(path, records.map { |record| "#{JSON.generate(record)}\n" }.join)
    end

    def drop(path, &gone) = File.write(path, R.read(path).reject(&gone).map { |record| "#{JSON.generate(record)}\n" }.join)

    # The first `count` draws' first calls ended in a transport error the retries did not recover.
    def lose(path, count)
      records = R.read(path).each_with_index.map do |record, index|
        next record if index >= count

        record.slice(*%w[objective row model style sample max_output_tokens arm process recorded_at pid])
          .merge("reached" => false, "error" => "SimpleInference::TimeoutError: execution expired")
      end
      File.write(path, records.map { |record| "#{JSON.generate(record)}\n" }.join)
    end

    def git_tree(root)
      %w[e2e nexus sdks/ruby/lib].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
      system("git", "init", "-q", root, exception: true)
      File.write(File.join(root, "e2e", "probe.rb"), "probe")
      File.write(File.join(root, "sdks", "ruby", "lib", "cybros_agent.rb"), "sdk")
      commit(root, "nexus/kernel.rb", "kernel")
      root
    end

    def commit(root, file, text)
      File.write(File.join(root, file), text)
      system("git", "-C", root, "add", "-A", exception: true)
      system("git", "-C", root, "-c", "user.name=screen", "-c", "user.email=screen@example.com", "-c", "commit.gpgsign=false",
        "commit", "-q", "--no-verify", "-m", text, exception: true)
    end

    def head(root) = IO.popen(["git", "-C", root, "rev-parse", "HEAD"], &:read).strip
end
