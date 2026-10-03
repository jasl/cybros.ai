$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"
require "support/screen/definition"
require "support/screen/figures"
require "support/screen/stage0"

# STAGE 0 IN ITS REGISTERED ORDER, OVER REAL GIT TREES: a scratch repository with `main` at the base
# and a `with` worktree one commit ahead; the gates that need a tree's bundle (the bytes, the rates,
# the builder counterfactual, the door reader), a kernel boot (the replay), a pair of records (the
# dry run) or a paid call (the smoke) are the test's recorders, each writing what its real
# counterpart would. The base is the ref the definition names, main unless `base_ref` names another.
# A refusal names its step and leaves no stamp; a fake rehearsal reports the machine-state gates and
# skips the kernel's; a dry run stops at a rehearsal stamp with no smoke; a screen is launched once,
# and relaunched once only over the launch its ledger (the readout) holds, when that launch owed it.
# Pure Ruby and git over a tmpdir.
class ScreenStage0HarnessTest < Minitest::Test
  S = E2E::Screen
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)
  DESIGN = "e2e/support/fixtures/screen/fake/design.md".freeze

  def test_every_gate_runs_in_the_registered_order_and_the_stamp_is_written_last
    with_screen do |trees, home, definition|
      calls = []
      stage0 = stage0(definition, trees, home, "real", calls: calls)
      path = stage0.call
      assert_equal %w[busy bytes rates replay counterfactual door_reader dry smoke], calls.map(&:first)
      stamp = S::Stamp.read(home)
      assert_equal path, S::Stamp.path(home)
      assert_equal %w[real none], stamp.values_at("mode", "transport_diff")
      assert_equal "nexus/lib/nexus/tool_registry/graph.rb", stamp.fetch("allowlist_diff")
      assert_equal "account,line,list,one,only,per,return", stamp.fetch("stems.primary.task.G0"), "the stimulus against the arm's added lines"
      assert_equal "built 2, mismatches 0", stamp.fetch("replay.with.declared")
      assert_equal "scripts 2, builds 2 in both trees", stamp.fetch("counterfactual.declared")
      assert_equal "the register holds: 2 records", stamp.fetch("door_reader")
      assert_equal ["main", stamp.fetch("base")], stamp.values_at("base_ref", "base_ref_head"), "a definition naming no base_ref reads main"
      assert_equal "none", stamp.fetch("sim.stops"), "the dry run's figures ride the stamp"
      assert_equal "0.090000", stamp.fetch("smoke_spend_usd")
      assert_equal definition.jobs, S::Stamp.jobs(stamp)
      assert_equal "25.0", stamp.fetch("watch.spend_stop_usd")
      assert_equal %w[mode screen definition_sha256], stamp.keys.first(3)
      assert_equal S::Corpus::FILES.keys.map { |id| S::Corpus.sha256(id) }, S::Corpus::FILES.keys.map { |id| stamp.fetch("corpus.#{id}") },
        "the tracked extracts the replay reads ride the stamp"
      assert_equal "launched_at", stamp.keys.last
    end
  end

  def test_each_tree_gate_refuses_by_name_and_leaves_no_stamp
    {
      "uncommitted changes" => ->(trees) { File.write(File.join(trees.fetch("with"), "e2e/new.rb"), "x\n") },
      "not the base" => ->(trees) { commit(trees.fetch("without"), "docs/a.md", "moved\n") },
      "past the base" => ->(trees) { commit(File.join(File.dirname(trees.fetch("with")), "repo"), "docs/b.md", "main moved\n") },
      "shared transport" => ->(trees) { commit(trees.fetch("with"), "e2e/support/manual_client.rb", "changed\n") },
      "outside the allowlist" => ->(trees) { commit(trees.fetch("with"), "nexus/app/models/user.rb", "changed\n") },
    }.each do |why, spoil|
      with_screen do |trees, home, definition|
        spoil.call(trees)
        error = assert_raises(S::Refused, why) { stage0(definition, trees, home, "real").call }
        assert_match(/\Astage 0 trees: .*#{why}/, error.message)
        refute File.exist?(S::Stamp.path(home)), why
      end
    end
  end

  # The readout directory of this very screen is not a dirty tree: a same-day relaunch finds it.
  def test_the_screens_own_untracked_readout_is_not_dirt
    with_screen do |trees, home, definition|
      readout = File.join(trees.fetch("with"), "e2e/artifacts/screen-readouts", definition.name)
      FileUtils.mkdir_p(readout)
      File.write(File.join(readout, "analysis.md"), "verdict\n")
      stage0(definition, trees, home, "real").call
      assert File.exist?(S::Stamp.path(home))
    end
  end

  # THE LOAD GATE IS THE MACHINE'S CORE COUNT: a load under it launches and is stamped with the
  # ceiling it met; a load at it refuses by name.
  def test_the_load_gate_is_the_machines_core_count
    assert_in_delta Etc.nprocessors.to_f, S::Stage0::LOAD_CEILING
    with_screen do |trees, home, definition|
      stage0(definition, trees, home, "real", busy: -> { [[], S::Stage0::LOAD_CEILING - 0.5] }).call
      stamp = S::Stamp.read(home)
      assert_equal (S::Stage0::LOAD_CEILING - 0.5).to_s, stamp.fetch("load_1min")
      assert_equal S::Stage0::LOAD_CEILING.to_s, stamp.fetch("load_ceiling")
    end
    with_screen do |trees, home, definition|
      error = assert_raises(S::Refused) { stage0(definition, trees, home, "real", busy: -> { [[], S::Stage0::LOAD_CEILING] }).call }
      assert_match(/stage 0 load: the one-minute load is .* not under #{Regexp.escape(S::Stage0::LOAD_CEILING.to_s)}/, error.message)
    end
  end

  def test_the_later_gates_refuse_by_name
    {
      "load" => { busy: -> { [["123 rake live_evals"], 0.5] } },
      "stems" => { stimulus: "Weigh one account." },
      "replay" => { mismatches: 1 },
      "counterfactual" => { counterfactual: "over declared the with builder builds 1 scripts the without builder refuses" },
      "door_reader" => { door_reader: "the door reader differs from the register on 1 of 2" },
      "dry" => { stop: "zero-effect LAND 4.1 % > 3 %" },
      "smoke" => { smoke_exit: 1 },
    }.each do |step, spoil|
      with_screen do |trees, home, definition|
        error = assert_raises(S::Refused, step) { stage0(definition, trees, home, "real", **spoil).call }
        assert error.message.start_with?("stage 0 #{step}: "), error.message
        refute File.exist?(S::Stamp.path(home)), step
      end
    end
  end

  # A FAKE REHEARSAL runs on a working tree: the tree, load and stem gates report; the kernel's
  # gates are skipped; the smoke runs; the stamp carries the fake clocks.
  def test_a_fake_rehearsal_reports_the_machine_gates_and_skips_the_kernels
    with_screen do |trees, home, definition|
      File.write(File.join(trees.fetch("with"), "e2e/new.rb"), "x\n")
      calls = []
      stage0(definition, trees, home, "fake", calls: calls, busy: -> { [["123 rake e2e"], 9.0] }).call
      stamp = S::Stamp.read(home)
      assert_match(/\AREPORTED, not enforced \(fake\): the with tree .* uncommitted/, stamp.fetch("stage0.trees"))
      assert stamp.fetch("stage0.load").start_with?("REPORTED")
      %w[replay counterfactual door_reader dry].each { |step| assert_equal "skipped (fake)", stamp.fetch("stage0.#{step}"), step }
      assert_equal %w[busy bytes rates smoke], calls.map(&:first)
      assert_equal "600.0", stamp.fetch("watch.wall_stop_seconds")
      assert stamp.key?("tree.with.state"), "the watch still checks the trees it was stamped on"
    end
  end

  # A clone with no local `main` (a CI checkout) cannot read the base; a rehearsal reports that and
  # still stamps every tree's state, which the watch and the analysis compare against.
  def test_a_rehearsal_without_main_still_stamps_the_trees_states
    with_screen do |trees, home, definition|
      repo = File.join(File.dirname(trees.fetch("with")), "repo")
      git(repo, "checkout", "-q", "--detach")
      git(repo, "branch", "-q", "-D", "main")
      stage0(definition, trees, home, "fake").call
      stamp = S::Stamp.read(home)
      assert_match(/\AREPORTED, not enforced \(fake\): git merge-base failed/, stamp.fetch("stage0.trees"))
      assert_equal %w[tree.with.state tree.without.state], stamp.keys.grep(/\Atree\..*\.state\z/)
    end
  end

  def test_a_dry_run_enforces_the_free_gates_and_stops_at_a_rehearsal_stamp_without_a_smoke
    with_screen do |trees, home, definition|
      calls = []
      stage0(definition, trees, home, "dry", calls: calls).call
      assert_equal "skipped (dry)", S::Stamp.read(home).fetch("stage0.smoke")
      refute_includes calls.map(&:first), "smoke"
      assert_equal %w[busy bytes rates replay counterfactual door_reader dry], calls.map(&:first)
    end
    %w[counterfactual door_reader].each do |step|
      with_screen do |trees, home, definition|
        error = assert_raises(S::Refused, step) { stage0(definition, trees, home, "dry", step.to_sym => "refused").call }
        assert_equal "stage 0 #{step}: refused", error.message
      end
    end
  end

  # THE BASE IS THE REF THE DEFINITION NAMES: a screen of a candidate stacked on a feature branch —
  # its without tree at that branch — is not the base under main, whose merge base with the with
  # tree is main's own head; under `base_ref` it is, and the held-out check reads the candidate's own
  # lines alone, never the feature branch's.
  def test_the_base_is_the_ref_the_definition_names
    with_stacked_screen do |trees, home, definition|
      error = assert_raises(S::Refused) { stage0(definition, trees, home, "real").call }
      assert_match(/\Astage 0 trees: the without tree is at \h{8}, not the base \h{8}/, error.message)

      stacked = definition.with(base_ref: "ladder")
      stage0(stacked, trees, home, "real", stimulus: "Weigh each account per line.").call
      stamp = S::Stamp.read(home)
      assert_equal ["ladder", stamp.fetch("head.without"), stamp.fetch("head.without")], stamp.values_at("base_ref", "base", "base_ref_head")
      assert_equal "line,per", stamp.fetch("stems.primary.task.G0"), "the stacked commit's added line alone: the ladder's `account` is not read"
    end
  end

  def test_a_base_ref_past_the_base_refuses
    with_stacked_screen do |trees, home, definition|
      commit(File.join(File.dirname(trees.fetch("with")), "ladder"), "docs/c.md", "ladder moved\n")
      error = assert_raises(S::Refused) { stage0(definition.with(base_ref: "ladder"), trees, home, "real").call }
      assert_match(/\Astage 0 trees: ladder is at \h{8}, past the base \h{8}: merge ladder into the with branch first\z/, error.message)
    end
  end

  def test_a_home_is_stamped_once
    with_screen do |trees, home, definition|
      stage0(definition, trees, home, "real").call
      error = assert_raises(S::Refused) { stage0(definition, trees, home, "real").call }
      assert_match(/\Astage 0 preconditions: .*stamped once/, error.message)
    end
  end

  # THE ONE RELAUNCH rides a registered stop, carries its own spend stop, and is never relaunched —
  # here with no readout of the launch, so the superseded home's own stop is read.
  def test_the_one_relaunch
    with_screen do |trees, home, definition|
      old = File.join(home, "old")
      stamped(old, [%w[mode real], ["screen", definition.name]])
      error = assert_raises(S::Refused) { stage0(definition, trees, File.join(home, "new1"), "real", supersedes: old).call }
      assert_includes error.message, "no registered stop"

      stopped(old, "MANUAL looks wrong — names no harness-fault class and record id: NOT LANDED, no relaunch owed")
      error = assert_raises(S::Refused) { stage0(definition, trees, File.join(home, "new2"), "real", supersedes: old).call }
      assert_includes error.message, "no relaunch is owed"

      stopped(old, "STORM 3 with m: 3 of 3 calls unreached (100.0 %)")
      fresh = File.join(home, "new3")
      stage0(definition, trees, fresh, "real", supersedes: old).call
      stamp = S::Stamp.read(fresh)
      assert stamp.fetch("supersedes").start_with?("#{old} (STORM")
      assert_equal "25.0", stamp.fetch("watch.spend_stop_usd"), "the relaunch's own stop, nothing carried"

      assert_equal S::Stamp.sha256(old), stamp.fetch("supersedes_stamp_sha256"), "the stamp the relaunch's readout moves aside"

      error = assert_raises(S::Refused) { stage0(definition, trees, File.join(home, "new4"), "real", supersedes: fresh).call }
      assert_includes error.message, "one relaunch is spent"

      other = File.join(home, "other")
      stamped(other, [%w[mode real], %w[screen another-screen]])
      stopped(other, "STORM 3 with m: 3 of 3 calls unreached (100.0 %)")
      error = assert_raises(S::Refused) { stage0(definition, trees, File.join(home, "new5"), "real", supersedes: other).call }
      assert_includes error.message, "launched \"another-screen\", not fake-rehearsal"
    end
  end

  # THE LEDGER IS THE READOUT: a screen whose readout holds a launch is not launched afresh; its one
  # relaunch supersedes that very launch when its analysis owes one — a stop, a kernel finding, lost
  # draws over the floor, none of which need a STOPPED file — and a second relaunch of it is refused
  # once the first is read out.
  def test_the_readout_is_the_screens_ledger
    with_screen do |trees, home, definition|
      first = File.join(home, "first")
      stamped(first, [%w[mode real], ["screen", definition.name], ["launched_at", "2026-09-28T10:00:00Z"]])
      read_out(trees, definition, first, verdict: "LAND", relaunch: "none")
      error = assert_raises(S::Refused) { stage0(definition, trees, File.join(home, "fresh"), "real").call }
      assert_match(/\Astage 0 preconditions: .* reads out the launch of 2026-09-28T10:00:00Z: a screen is launched once/, error.message)
      error = assert_raises(S::Refused) { stage0(definition, trees, File.join(home, "decided"), "real", supersedes: first).call }
      assert_includes error.message, "read out LAND: no relaunch is owed"

      FileUtils.rm_rf(S::Readout.dir(trees.fetch("with"), definition))
      read_out(trees, definition, first, verdict: "KERNEL-FINDING", relaunch: "kernel-finding")
      relaunch = File.join(home, "relaunch")
      stage0(definition, trees, relaunch, "real", supersedes: first).call
      assert_equal "#{first} (KERNEL-FINDING kernel-finding)", S::Stamp.read(relaunch).fetch("supersedes")

      read_out(trees, definition, relaunch, verdict: "LAND", relaunch: "none")
      error = assert_raises(S::Refused) { stage0(definition, trees, File.join(home, "again"), "real", supersedes: first).call }
      assert_includes error.message, "the one relaunch is spent"
    end
  end

  private

    # A scratch repository whose `main` holds the base; the `without` tree is a detached worktree
    # at it, the `with` worktree one allowlisted commit ahead, adding a line to the registry text —
    # one carrying a non-ASCII character, as the registry's text does, so the stems step reads the
    # diff as UTF-8 whatever the locale.
    def with_screen
      Dir.mktmpdir("screen-stage0") do |scratch|
        repo = File.join(scratch, "repo")
        FileUtils.mkdir_p(repo)
        git(repo, "init", "-q", "-b", "main")
        { DESIGN => File.read(File.expand_path("../#{DESIGN.delete_prefix("e2e/")}", __dir__)),
          "nexus/lib/nexus/tool_registry/graph.rb" => "Plain tool calls in ONE message.\n",
          "e2e/support/manual_client.rb" => "# client\n", "docs/a.md" => "a\n" }.each do |path, text|
          FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
          File.write(File.join(repo, path), text)
        end
        git(repo, "add", ".")
        git(repo, *AUTHOR, "commit", "-qm", "base")
        with = File.join(scratch, "with")
        git(repo, "worktree", "add", "-q", "-b", "feat", with)
        commit(with, "nexus/lib/nexus/tool_registry/graph.rb",
          "Plain tool calls in ONE message.\nList one account per line — only the returns; weigh not the rest.\n")
        without = File.join(scratch, "without")
        git(repo, "worktree", "add", "-q", "--detach", without, "main")
        yield({ "with" => with, "without" => without }, File.join(scratch, "home"), definition(scratch))
      end
    end

    # A scratch repository whose `main` holds the base, a `ladder` branch one commit ahead of it where
    # the without tree sits, and the with worktree one commit ahead of `ladder` — a candidate stacked
    # on a feature branch, as the Q screen's is on the door ladder.
    def with_stacked_screen
      with_screen do |trees, home, definition|
        scratch = File.dirname(trees.fetch("with"))
        repo = File.join(scratch, "repo")
        ladder = File.join(scratch, "ladder")
        git(repo, "worktree", "add", "-q", "-b", "ladder", ladder, "main")
        commit(ladder, "nexus/lib/nexus/tool_registry/graph.rb", "Plain tool calls in ONE message.\nList one account.\n")
        stacked = File.join(scratch, "stacked")
        git(repo, "worktree", "add", "-q", "-b", "q", stacked, "ladder")
        commit(stacked, "nexus/lib/nexus/tool_registry/graph.rb", "Plain tool calls in ONE message.\nList one account.\nOne per line.\n")
        without = File.join(scratch, "at-ladder")
        git(repo, "worktree", "add", "-q", "--detach", without, "ladder")
        yield({ "with" => stacked, "without" => without }, home, definition)
      end
    end

    # The fake definition with the kernel's gates registered, so every step runs.
    def definition(scratch)
      dir = File.join(scratch, "definition")
      FileUtils.mkdir_p(dir)
      yaml = YAML.safe_load_file(File.join(FAKE, "screen.yml"))
      yaml["stage0"] = yaml.fetch("stage0").merge("replay" => { "corpus" => ["declared"], "ordered" => { "with" => true, "without" => true } },
        "counterfactual" => { "corpus" => ["declared"] }, "door_reader" => { "expected" => "register.yml" }, "dry" => { "pair" => "pairs/null" })
      File.write(File.join(dir, "screen.yml"), YAML.dump(yaml))
      File.write(File.join(dir, "register.yml"), "{}\n")
      S::Definition.load(dir)
    end

    def stage0(definition, trees, home, mode, calls: [], busy: -> { [[], 0.5] }, stimulus: "Read lib/alpha.rb: list one account per line, only the returns.",
               mismatches: 0, counterfactual: nil, door_reader: nil, stop: nil, smoke_exit: 0, supersedes: nil)
      S::Stage0.new(definition: definition, trees: trees, home: home, mode: mode, supersedes: supersedes,
        busy: -> { calls << ["busy"] && busy.call },
        bytes: recorder(calls, "bytes") { |home_dir| objective_files(definition, home_dir, stimulus) },
        rates: recorder(calls, "rates") { [["rates_sha256", "0" * 64]] },
        replay: recorder(calls, "replay") do
          trees.map { |tag, _| ["replay.#{tag}.declared", replayed(tag, mismatches)] }
        end,
        counterfactual: recorder(calls, "counterfactual") { refused_or(counterfactual, [["counterfactual.declared", "scripts 2, builds 2 in both trees"]]) },
        door_reader: recorder(calls, "door_reader") { refused_or(door_reader, [["door_reader", "the register holds: 2 records"]]) },
        analysis: Data.define(:calls, :stop) do
          def dry(*) = calls << ["dry"] && S::Figures.new(clauses: [], finding: [], figures: [], stops: Array(stop))
        end.new(calls: calls, stop: stop),
        smoke_runner: ->(jobs) { calls << ["smoke"] && smoke(home, jobs, smoke_exit) },
        pricer: ->(_record) { 0.015 })
    end

    # A collaborator answering `call(**)` with what its block computes from the home.
    def recorder(calls, name, &answer)
      Object.new.tap do |object|
        object.define_singleton_method(:call) do |home: nil, **|
          calls << [name]
          answer.arity.zero? ? answer.call : answer.call(home)
        end
      end
    end

    def refused_or(refusal, pairs) = refusal ? raise(S::Refused, refusal) : pairs

    def replayed(tag, mismatches)
      raise S::Refused, "the replay found #{mismatches} mismatches in the #{tag} tree over declared" if mismatches.positive?

      "built 2, mismatches 0"
    end

    def objective_files(definition, home, stimulus)
      definition.arms.each do |arm|
        FileUtils.mkdir_p(S::Bytes.dir(home, arm.id))
        %w[G0 T5].each { |id| File.write(File.join(S::Bytes.dir(home, arm.id), "objective.task.#{id}.txt"), stimulus) }
      end
      [["bytes.base.task_probe.task.nexus", "2934 #{"a" * 64}"]]
    end

    def smoke(home, jobs, status)
      jobs.each do |job|
        FileUtils.mkdir_p(job.path(home))
        FileUtils.mkdir_p(File.dirname(S::Smoke.log(home, job)))
        usage = { "input_tokens" => 9_020, "output_tokens" => 30, "cache_creation_tokens" => 9_000 }
        draws = Array.new(job.n) do |i|
          { "arm" => job.arm, "process" => job.index.to_s, "model" => job.model, "objective" => "O1", "sample" => i + 1,
            "usage" => i.zero? ? usage : usage.merge("cache_read_tokens" => 9_000) }
        end
        File.write(File.join(job.path(home), "records.jsonl"), draws.map { |draw| "#{JSON.generate(draw)}\n" }.join)
        File.write(S::Smoke.log(home, job), "exit=#{status}\n")
      end
    end

    def stamped(home, pairs) = S::Stamp.write(home, pairs)

    # A launch's readout in the with tree's ledger: its stamp beside an analysis whose machine lines
    # carry `verdict` and `relaunch`; a relaunch's readout moves the earlier one aside.
    def read_out(trees, definition, home, verdict:, relaunch:)
      File.write(File.join(home, "analysis.md"), "# a\n\n#{S::Analysis::MACHINE}\n\n```text\nverdict=#{verdict}\nrelaunch=#{relaunch}\n```\n")
      File.write(File.join(home, "counts.txt"), "ok\n")
      S::Readout.write(home: home, definition: definition, root: trees.fetch("with"), cells: [])
    end

    def stopped(home, reason)
      FileUtils.mkdir_p(File.join(home, "logs"))
      File.write(File.join(home, "logs", "STOPPED"), "2026-09-28T10:00:00Z #{reason}\n")
    end

    AUTHOR = ["-c", "user.name=screen", "-c", "user.email=screen@example.com"].freeze

    def commit(root, path, text)
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
      git(root, "add", path)
      git(root, *AUTHOR, "commit", "-qm", "change #{path}")
    end

    def git(root, *args)
      out, status = Open3.capture2e("git", "-C", root, *args)
      assert status.success?, "git #{args.join(" ")}: #{out}"
    end
end
