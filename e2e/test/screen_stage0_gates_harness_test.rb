$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "support/screen/definition"
require "support/screen/stage0"

# STAGE 0'S BUNDLE-BOUND GATES, EACH ON ITS OWN: the bytes each arm sends, read by the real
# `bytes_cli.rb` under this checkout's bundle (offline — nothing it reads calls a provider) and
# stamped one pair per file it wrote; the rates, which both trees must answer alike and whose answer
# is written whole; the replay, one mismatch in either tree refusing and each tree replayed
# under its own order rule; the door reader and the builder counterfactual, each through its real
# CLI on this checkout as both trees, the door definition's register met and every script kinded.
# The Stage 0 test swaps these for recorders, and the fake screen skips the last two; here they run.
class ScreenStage0GatesHarnessTest < Minitest::Test
  S = E2E::Screen
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)
  ROOT = File.expand_path("../..", __dir__)
  Group = Data.define(:scripts, :tool_names, :declarations)
  Replayed = Data.define(:mismatches, :summary)

  # THE BYTES: every file the CLI wrote under an arm's directory is one `bytes.<arm>.<name>` pair,
  # its size and its sha256 — the stamp carries what each arm sends, not merely that it was read.
  def test_the_bytes_step_stamps_one_pair_per_file_each_arm_wrote
    definition = S::Definition.load(FAKE)
    Dir.mktmpdir("screen-bytes") do |home|
      pairs = S::Bytes.call(definition: definition, trees: { "with" => ROOT, "without" => ROOT }, home: home)
      written = definition.arms.flat_map do |arm|
        Dir[File.join(S::Bytes.dir(home, arm.id), "*.txt")].map do |path|
          bytes = File.binread(path)
          ["bytes.#{arm.id}.#{File.basename(path, ".txt")}", "#{bytes.bytesize} #{Digest::SHA256.hexdigest(bytes)}"]
        end
      end
      assert_equal 2 * 16, written.size, "per arm: two compose texts, four task entries, six objectives, four task fixtures"
      assert_equal written.sort, pairs.sort
      assert_includes pairs.map(&:first), "bytes.candidate.objective.task.G0"
      fixture = File.read(File.join(S::Bytes.dir(home, "candidate"), "fixture.task.SP3A.txt"), encoding: Encoding::UTF_8)
      assert_equal %w[lib/auth/session.rb patch.diff], JSON.parse(fixture).keys, "the fixture's paths, sorted, beside their bytes"
      assert_includes JSON.parse(fixture).fetch("patch.diff"), "+++ b/lib/auth/session.rb"
      assert_equal "{}", File.read(File.join(S::Bytes.dir(home, "candidate"), "fixture.task.G0.txt")), "no fixture: an empty project"
      claims = File.read(File.join(S::Bytes.dir(home, "candidate"), "fixture.task.D1P.txt"), encoding: Encoding::UTF_8)
      assert_equal %w[lib/balance.rb lib/ledger.rb lib/posting.rb], JSON.parse(claims).keys, "a door objective's fixture directory"
    end
  end

  def test_the_bytes_step_refuses_a_tree_whose_reader_fails_and_shows_its_stderr
    definition = S::Definition.load(FAKE)
    failing = ->(_argv, chdir:, env: {}) { ["", false, "bundler: command not found: ruby\n"] }
    error = assert_raises(S::Refused) do
      S::Bytes.call(definition: definition, trees: { "with" => ROOT, "without" => ROOT }, home: Dir.tmpdir, command: failing)
    end
    assert_includes error.message, "command not found"
  end

  # THE RATES: each smoke model is priced by the same schedules as the cells' models, so each
  # tree's derivation is asked for both; the two trees' documents must match.
  def test_the_rates_are_asked_for_every_drawn_model_and_both_trees_must_agree
    with_definition("smoke" => smoke_with("fake/chat-control")) do |definition|
      Dir.mktmpdir("screen-rates") do |home|
        asked = []
        documents = { "/w" => { "a" => 1 }, "/wo" => { "a" => 2 } }
        derive = lambda do |root:, models:|
          asked << [root, models]
          documents.fetch(root)
        end
        error = assert_raises(S::Refused) do
          S::Rates.call(definition: definition, trees: { "with" => "/w", "without" => "/wo" }, home: home, derive: derive)
        end
        assert_includes error.message, "price the screen differently"
        refute File.exist?(S::Rates.path(home)), "nothing is written for a pair that disagrees"
        assert_equal [["/w", definition.drawn_models], ["/wo", definition.drawn_models]], asked
        assert_includes definition.drawn_models, "fake/chat-control", "the smoke's own lane is priced too"
      end
    end
  end

  def test_agreeing_trees_write_the_document_and_stamp_its_sha
    definition = S::Definition.load(FAKE)
    Dir.mktmpdir("screen-rates") do |home|
      document = { "fake/chat-a" => { "settles_money" => true } }
      pairs = S::Rates.call(definition: definition, trees: { "with" => "/w", "without" => "/wo" }, home: home,
        derive: ->(root:, models:) { document })
      assert_equal "#{JSON.pretty_generate(document)}\n", File.read(S::Rates.path(home))
      assert_equal [["rates_sha256", Digest::SHA256.file(S::Rates.path(home)).hexdigest]], pairs
    end
  end

  # A tree whose derivation fails — its runner, or a lane settlement writes no money for — is a
  # refusal naming the tree.
  def test_a_tree_whose_derivation_fails_is_refused_by_name
    definition = S::Definition.load(FAKE)
    Dir.mktmpdir("screen-rates") do |home|
      derive = ->(root:, models:) { raise "a screen prices every lane it pays for in USD: x is unpriced" }
      error = assert_raises(S::Refused) do
        S::Rates.call(definition: definition, trees: { "with" => "/w", "without" => "/w" }, home: home, derive: derive)
      end
      assert_equal "the rates runner failed in /w: RuntimeError: a screen prices every lane it pays for in USD: x is unpriced", error.message
    end
  end

  # THE CAPTURE a gate reads data through keeps stderr apart: a warning a child prints never
  # joins the answer, and a failure's stderr is there for the refusal.
  def test_the_capture_keeps_stderr_out_of_the_answer
    out, ok, err = S::CAPTURE.call([Gem.ruby, "-e", "warn 'a warning'; puts '{}'"], chdir: Dir.tmpdir)
    assert_equal ["{}\n", true, "a warning\n"], [out, ok, err]
    out, ok, err = S::CAPTURE.call([Gem.ruby, "-e", "warn 'it broke'; exit 3"], chdir: Dir.tmpdir)
    assert_equal ["", false, "it broke\n"], [out, ok, err]
  end

  # THE REPLAY: each corpus group under the tool set its round declared, in each tree under that
  # tree's order rule; one mismatch anywhere refuses.
  def test_the_replay_passes_each_tree_its_own_order_rule_and_stamps_each_trees_summary
    definition = replay_definition("with" => true, "without" => false)
    calls = []
    pairs = S::ReplayGate.call(definition: definition, trees: { "with" => "/w", "without" => "/wo" },
      replay: replayer(calls, {}), corpus: corpus)
    assert_equal [["/w", true, %w[a.js b.js], %w[read_file]], ["/w", true, %w[c.js], %w[bash]],
                  ["/wo", false, %w[a.js b.js], %w[read_file]], ["/wo", false, %w[c.js], %w[bash]]], calls
    assert_equal [["replay.with.declared", "built 2 | built 1"], ["replay.without.declared", "built 2 | built 1"]], pairs
  end

  def test_one_mismatch_in_either_tree_refuses_the_replay
    %w[/w /wo].each do |root|
      definition = replay_definition("with" => true, "without" => true)
      error = assert_raises(S::Refused, root) do
        S::ReplayGate.call(definition: definition, trees: { "with" => "/w", "without" => "/wo" },
          replay: replayer([], { [root, "c.js"] => ["c.js: harness lowered, kernel refused"] }), corpus: corpus)
      end
      tag = root == "/w" ? "with" : "without"
      assert_equal "the replay found 1 mismatches in the #{tag} tree over declared", error.message
    end
  end

  # THE DOOR READER: `door_reader_cli.rb` under this checkout's bundle kinds every tracked door
  # record by the task bench's own door, and the tally meets the door definition's register.
  def test_the_door_reader_cli_meets_the_register
    definition = S::Definition.load(FAKE)
    definition = definition.with(stage0: definition.stage0.merge("door_reader" => { "expected" => "../corpus/door_reader_expected.yml" }))
    pairs = S::DoorReader.call(definition: definition, trees: { "with" => ROOT, "without" => ROOT })
    assert_equal ["door_reader"], pairs.map(&:first)
    assert pairs.first.last.start_with?("the register holds: 13 records"), pairs.first.last
  end

  # THE COUNTERFACTUAL: `counterfactual_cli.rb` reads one corpus in each tree — the without tree's
  # builder alone, the with tree's with the door — and every script builds alike and is kinded.
  def test_the_counterfactual_cli_builds_alike_and_kinds_every_script
    definition = S::Definition.load(FAKE)
    narrowed = definition.with(stage0: definition.stage0.merge("counterfactual" => { "corpus" => ["declared"] }))
    pairs = S::Counterfactual.call(definition: narrowed, trees: { "with" => ROOT, "without" => ROOT })
    assert_equal %w[counterfactual.declared counterfactual.declared.door_kind], pairs.map(&:first)
    assert_match(/\Ascripts 4, builds \d+ in both trees;/, pairs.first.last)
    assert_match(/compose_steps \d+/, pairs.last.last)
  end

  private

    def smoke_with(model)
      YAML.safe_load_file(File.join(FAKE, "screen.yml")).fetch("smoke").merge("models" => ["fake/chat-a", model])
    end

    def with_definition(change)
      Dir.mktmpdir("screen-definition") do |dir|
        yaml = YAML.safe_load_file(File.join(FAKE, "screen.yml")).merge(change)
        File.write(File.join(dir, "screen.yml"), YAML.dump(yaml))
        yield S::Definition.load(dir)
      end
    end

    def replay_definition(ordered)
      with_definition({}) { |definition| definition }
        .with(stage0: { "replay" => { "corpus" => ["declared"], "ordered" => ordered } })
    end

    # Two groups of one corpus, each under its own round's tool set.
    def corpus
      lambda do |id|
        assert_equal "declared", id
        [Group.new(scripts: %w[a.js b.js], tool_names: %w[read_file], declarations: [{ "name" => "read_file" }]),
         Group.new(scripts: %w[c.js], tool_names: %w[bash], declarations: [{ "name" => "bash" }])]
      end
    end

    # A replay answering each group's scripts; `mismatched` names a (root, script) that mismatches.
    def replayer(calls, mismatched)
      lambda do |scripts, root:, tool_names:, declarations:, ordered:|
        calls << [root, ordered, scripts, tool_names]
        assert_equal tool_names, declarations.map { |declaration| declaration.fetch("name") }
        Replayed.new(mismatches: scripts.flat_map { |script| mismatched.fetch([root, script], []) }, summary: "built #{scripts.size}")
      end
    end
end
