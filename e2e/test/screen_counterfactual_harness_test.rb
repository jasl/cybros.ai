$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "mini_racer"
require "minitest/autorun"
require "support/screen/counterfactual"
require "support/screen/definition"
require "support/task_bench"
require "support/task_bench/door"

# THE BUILDER COUNTERFACTUAL: each tree's own builder over every stored first script the definition
# names, each under the names its group declared. The same scripts build in both trees or the launch
# stops; the refusals a builder repair rewords are listed old → new; in the with tree the task
# bench's `Door.kind` answers a kind for every script, and one that raises stops the launch. The
# reading runs here on this tree's builder over authored corpus scripts; the trees' readings are the
# test's. Pure Ruby over the tracked corpus.
class ScreenCounterfactualHarnessTest < Minitest::Test
  S = E2E::Screen
  C = E2E::Screen::Counterfactual
  DIR = File.expand_path("../support/fixtures/screen/fake", __dir__)
  TREES = { "with" => "/trees/with", "without" => "/trees/without" }.freeze

  # THE READING, in this tree: a script that builds and one the builder refuses by its "all" group,
  # each with the corpus and id it came from; a door answers each as a compose call under its
  # group's declared entries, and a door that raises is kept as the row's error, never a crash.
  def test_the_reading_builds_each_script_and_kinds_it_as_a_compose_call
    rows = C.read("declared")
    assert_equal 4, rows.size
    assert_equal({ "corpus" => "declared", "id" => "single-model", "built" => true },
      rows.find { |row| row["id"] == "single-model" })
    assert_equal({ "corpus" => "declared", "id" => "malformed-script", "built" => false, "bucket" => "syntax" },
      rows.find { |row| row["id"] == "malformed-script" })

    seen = []
    door = lambda do |calls, declared|
      seen << [calls, declared]
      raise NoMethodError, "undefined method 'fetch' for nil" if JSON.parse(calls.first.fetch("arguments")).fetch("script").include?("Review")

      "compose_steps"
    end
    kinded = C.read("declared", door: door)
    call = seen.first.first
    assert_equal [%w[call_1 compose]], call.map { |c| c.values_at("id", "name") }
    assert_equal E2E::Screen::Corpus.entries("declared").first.script, JSON.parse(call.first.fetch("arguments")).fetch("script")
    assert_equal E2E::Screen::Corpus.declared_sets.first.fetch("declarations"), seen.first.last, "the entries its round declared"
    assert(kinded.all? { |row| row.key?("door_kind") ^ row.key?("door_error") })
    assert(kinded.any? { |row| row["door_error"] == "NoMethodError: undefined method 'fetch' for nil" })
  end

  # THE STEP: both trees read, the with tree with the door; the same builds stamp the counts, the
  # listed refusals old → new, each reworded script, and the with tree's door kinds.
  def test_the_same_builds_stamp_the_listed_refusals_and_the_door_kinds
    ran = []
    pairs = C.call(definition: definition, trees: TREES, command: trees(ran, without: reading, with: reading(moved: true, door: true)))
    assert_equal [["/trees/without/e2e", %w[--corpus declared]], ["/trees/with/e2e", %w[--corpus declared --door 1]]],
      ran.map { |argv, chdir| [chdir, argv.drop(4)] }
    assert_equal ["counterfactual.declared", "scripts 4, builds 2 in both trees; listed refusals old → new: group_reference → group_reference 1, nested_list → chain_reference 1"],
      pairs.first
    assert_equal ["counterfactual.declared.moved", "case-d (nested_list → chain_reference)"], pairs[1]
    assert_equal ["counterfactual.declared.door_kind", "compose_refused 2, compose_steps 2"], pairs.last
  end

  def test_a_build_difference_refuses
    gained = reading.map { |row| row["id"] == "case-c" ? row.except("bucket").merge("built" => true) : row }
    error = assert_raises(S::Refused) { C.call(definition: definition, trees: TREES, command: trees([], without: reading, with: door(gained))) }
    assert_equal "over declared the with builder builds 1 scripts the without builder refuses (case-c) and refuses 0 it builds ()", error.message
  end

  def test_a_door_that_raises_refuses
    broken = door(reading).map { |row| row["id"] == "case-a" ? row.except("door_kind").merge("door_error" => "TypeError: no implicit conversion") : row }
    error = assert_raises(S::Refused) { C.call(definition: definition, trees: TREES, command: trees([], without: reading, with: broken)) }
    assert_equal "over declared Door.kind raised on 1 scripts: case-a: TypeError: no implicit conversion", error.message
  end

  def test_a_tree_that_cannot_read_refuses_with_its_error
    failing = ->(_argv, chdir:) { ["", false, "LoadError: cannot load such file -- support/task_bench/door"] }
    error = assert_raises(S::Refused) { C.call(definition: definition, trees: TREES, command: failing) }
    assert_equal "the counterfactual could not run in /trees/without: LoadError: cannot load such file -- support/task_bench/door", error.message
  end

  # The task bench's own door answers a kind for every authored first script and never raises; the
  # launch's step reads the batch's as well.
  def test_the_task_benchs_door_kinds_every_authored_script
    rows = C.read("declared", door: ->(calls, declared) { E2E::TaskBench::Objectives.door(calls, declared: declared).kind })
    assert_equal [4, []], [rows.size, rows.select { |row| row.key?("door_error") }.first(3)]
  end

  private

    # The door screen's definition with the counterfactual over the authored corpus alone.
    def definition
      loaded = S::Definition.load(DIR)
      loaded.with(stage0: loaded.stage0.merge("counterfactual" => { "corpus" => %w[declared] }))
    end

    # Four scripts: two build, one refused by an "all" group, one by a nested list — reworded as a
    # chain by a repaired builder when `moved`.
    def reading(moved: false, door: false)
      rows = [
        { "corpus" => "declared", "id" => "case-a", "built" => true },
        { "corpus" => "declared", "id" => "case-b", "built" => true },
        { "corpus" => "declared", "id" => "case-c", "built" => false, "bucket" => "group_reference" },
        { "corpus" => "declared", "id" => "case-d", "built" => false, "bucket" => moved ? "chain_reference" : "nested_list" },
      ]
      door ? door(rows) : rows
    end

    def door(rows) = rows.map { |row| row.merge("door_kind" => row["built"] ? "compose_steps" : "compose_refused") }

    # Each tree answers its own rows, by the directory the command runs in.
    def trees(ran, without:, with:)
      lambda do |argv, chdir:|
        ran << [argv, chdir]
        rows = chdir == File.join(TREES.fetch("with"), "e2e") ? with : without
        [rows.map { |row| "#{JSON.generate(row)}\n" }.join, true, ""]
      end
    end
end
