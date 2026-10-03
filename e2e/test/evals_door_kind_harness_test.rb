$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "yaml"
require "support/evals"
require "support/screen/door_reader"

# The lane and screen readers classify the same authored rounds.
class EvalsDoorKindHarnessTest < Minitest::Test
  D = E2E::Evals::Drawing
  P = E2E::Evals::Predicates
  R = E2E::Screen::DoorReader
  REGISTER = File.expand_path("../support/fixtures/screen/corpus/door_reader_expected.yml", __dir__)

  def test_the_lanes_door_kind_reads_the_register
    records = E2E::Screen::Corpus.door_records
    assert_equal 13, records.size
    declared = R.declared
    tally = records.group_by { |record| R.key(record) }.transform_values do |own|
      own.map { |record| label(drawn(record), declared) }.tally.sort.to_h
    end
    assert_equal YAML.safe_load_file(REGISTER), tally.sort.to_h
  end

  # A drawing is read as the register reads a record: a compose door's `members` rides its label only
  # when the script built, and the round is the door's among the spine's first three.
  def test_a_drawn_record_labels_as_the_register_spells_it
    declared = R.declared
    looked = record([[call("bash", "command" => "cat claims.md; ls -R lib; pwd")], [call("task", "prompt" => "Refute C1.")], []])
    assert_equal "task_one@r2", label(drawn(looked), declared)
    refused = record([[call("compose", "script" => "nope(")], []])
    assert_equal "compose_refused@r1", label(drawn(refused), declared)
    scout = record([[call("ls", "path" => ".")], [call("read", "path" => "a")], [call("grep", "pattern" => "x")]])
    assert_equal "scout", label(drawn(scout), declared)
  end

  private

    # The record's rounds as the spine's rounds `r1…rN`, each fanning its calls in order.
    def drawn(record)
      rounds = record.fetch("rounds")
      rows = rounds.each_with_index.flat_map do |calls, i|
        calls.each_with_index.map { |call, j| D.tool("r#{i + 1}t#{j}", call.fetch("name"), after: ["r#{i + 1}"], input: call.fetch("input")) }
      end
      nodes = rounds.each_index.map { |i| D.n("r#{i + 1}", "model_task") } + rows.map { |row| D.n(row["key"], "tool_task") }
      D.trace(D.graph(nodes, []), rows, [])
    end

    # `<kind>@r<round>`, ` members=<n>` after a compose that built; `scout` where no round is the door.
    def label(trace, declared)
      kind = P.door_kind(trace, declared: declared)
      read = P.door_read(trace, declared: declared)
      if read.fetch("round")
        "#{kind}@r#{read.fetch("round")}#{" members=#{read.fetch("members")}" if kind.start_with?("compose_") && read.fetch("built") == true}"
      else
        kind
      end
    end

    def record(rounds) = { "bench" => "synthetic", "task" => "task-mail", "model" => "fixture/strong", "rounds" => rounds }

    def call(name, input) = { "name" => name, "input" => input }
end
