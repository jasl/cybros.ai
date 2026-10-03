$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "yaml"
require "support/screen/definition"
require "support/screen/door_reader"
require "support/task_bench"
require "support/task_bench/door"

# Synthetic rounds exercise door placement and classification without a model provider.
class ScreenDoorReaderHarnessTest < Minitest::Test
  S = E2E::Screen
  R = E2E::Screen::DoorReader
  DIR = File.expand_path("../support/fixtures/screen/fake", __dir__)
  Kinded = Data.define(:kind, :built, :members)
  KINDS = { "compose_flat" => 1, "compose_one" => 2, "compose_refused" => 1, "compose_steps" => 1,
            "none" => 1, "plain" => 1, "scout" => 1, "spawn" => 1, "start_process" => 1,
            "task_fan" => 1, "task_one" => 2 }.freeze
  ROUNDS = { "1" => 10, "2" => 1, "3" => 1, "scout" => 1 }.freeze

  def definition
    loaded = S::Definition.load(DIR)
    loaded.with(stage0: loaded.stage0.merge("door_reader" => { "expected" => "../corpus/door_reader_expected.yml" }))
  end

  def register = R.register(definition)

  def test_the_register_covers_distinct_door_kinds_and_rounds
    labels = register.values.flat_map { |own| own.flat_map { |label, count| [label] * count } }
    assert_equal [13, 13], [register.size, labels.size]
    assert_equal KINDS, labels.map { |label| label[/\A[a-z_]+/] }.tally.sort.to_h
    assert_equal ROUNDS, labels.map { |label| label[/@r(\d)/, 1] || "scout" }.tally.sort.to_h
    assert_equal({ "compose_steps@r1 members=2" => 1 }, register.fetch("synthetic w-joined model-a"))
  end

  # Without any kinding, the rule alone places every record: the register holds each (bench, task,
  # model) with exactly its runs, each at the round the look rule scores it at, three looks a scout.
  def test_every_corpus_record_sits_in_the_register_at_the_round_the_look_rule_scores
    records = S::Corpus.door_records.group_by { |record| R.key(record) }
    assert_equal records.keys.sort, register.keys.sort
    records.each do |key, own|
      scored = own.map { |record| record.fetch("rounds").index { |round| !R.look?(round) }&.then { |index| (index + 1).to_s } || "scout" }
      registered = register.fetch(key).flat_map { |label, count| [label[/@r(\d)/, 1] || "scout"] * count }
      assert_equal registered.sort, scored.sort, key
    end
  end

  # THE REGISTERED LOOK RULE: a stage of ReadClass's admitted commands, `pwd` or `tail` under `;`,
  # `&&`, `||` or `|`, one quieted stderr stripped; a second one, a write, a substitution or any other
  # command is a door. ReadClass's own admitted commands are looks here too.
  def test_the_look_rule
    look = ->(command) { R.look?([{ "name" => "bash", "input" => { "command" => command } }]) }
    assert look.("cat claims.md; ls -R lib; pwd"), "a semicolon-joined look"
    assert_nil E2E::TaskBench::ReadClass.bash_argv("cat claims.md; ls -R lib; pwd"), "ReadClass refuses the chain outright"
    assert look.("cat bin/rails 2>/dev/null | head -5")
    assert look.("grep -rn TODO lib && tail -n 5 log/test.log")
    refute look.("cat bin/fetch 2>/dev/null; ls bin 2>/dev/null"), "a second quieted stderr is a door, as the register read it"
    refute look.("cat a > b")
    refute look.("cat $(ls lib)")
    refute look.("ls `pwd`")
    refute look.("bin/rails test")
    refute look.("; ls"), "a stage with no command"
    %w[cat\ lib/a.rb ls\ -la wc\ -l\ lib/a.rb head\ -n\ 5\ lib/a.rb sed\ -n\ 1,5p\ lib/a.rb grep\ -n\ def\ lib/a.rb find\ lib\ -name\ *.rb].each do |command|
      refute_nil E2E::TaskBench::ReadClass.bash_argv(command.sub("*.rb", "a.rb")), command
      assert look.(command), command
    end
    assert R.look?([{ "name" => "read", "input" => {} }, { "name" => "grep", "input" => {} }, { "name" => "find", "input" => {} }])
    refute R.look?([{ "name" => "read", "input" => {} }, { "name" => "write", "input" => {} }])
    refute R.look?([]), "a round with no call is the model answering"
  end

  # THE TALLY: the first round that is not a look is kinded, handed in the wire shape of a message's
  # calls under the corpus's declared union; a compose that built carries its members; a round of
  # looks throughout is a scout.
  def test_the_tally_labels_each_record_by_the_kind_of_its_first_door
    records = [
      record("t-mail", [[call("read", "path" => "a")], [call("task", "prompt" => "go")]]),
      record("t-mail", [[call("compose", "script" => "g.model({ prompt: \"x\" });")]]),
      record("t-mail", [[call("compose", "script" => "nope(")]]),
      record("t-mail", [[call("ls", {})], [call("grep", "pattern" => "x")], [call("find", {})]]),
    ]
    seen = []
    door = lambda do |calls, declared|
      seen << [calls, declared.map { |entry| entry.dig("function", "name") }.size]
      case calls.first.fetch("name")
      when "task" then Kinded.new(kind: "task_one", built: nil, members: 1)
      when "compose"
        JSON.parse(calls.first.fetch("arguments")).fetch("script").start_with?("g.") ? Kinded.new(kind: "compose_one", built: true, members: 0) : Kinded.new(kind: "compose_refused", built: false, members: 0)
      else raise ArgumentError, "no door here"
      end
    end
    tally = R.tally(records, door: door, declared: R.declared)
    assert_equal({ "synthetic t-mail model-a" => { "compose_one@r1 members=0" => 1, "compose_refused@r1" => 1, "scout" => 1, "task_one@r2" => 1 } }, tally)
    assert_equal [{ "id" => "call_1", "name" => "task", "arguments" => "{\"prompt\":\"go\"}" }], seen.first.first
    assert_equal [11] * 3, seen.map(&:last), "the union of the names the corpus's rounds declared"
  end

  # THE STEP: the with tree's reading equal to the register stamps its totals; one (bench, task,
  # model) read otherwise refuses by name; a reader that could not run refuses with its error.
  def test_the_step_matches_the_register_and_refuses_a_difference_by_name
    definition = self.definition
    trees = { "with" => "/trees/with", "without" => "/trees/without" }
    ran = []
    answer = ->(read) { ->(argv, chdir:) { ran << [argv, chdir] && [JSON.generate(read), true, ""] } }
    pairs = R.call(definition: definition, trees: trees, command: answer.(register))
    assert_equal [[%w[bundle exec ruby support/screen/door_reader_cli.rb], "/trees/with/e2e"]], ran
    assert_equal ["door_reader"], pairs.map(&:first)
    assert pairs.first.last.start_with?("the register holds: 13 records; compose_flat 1, compose_one 2,"), pairs.first.last
    assert pairs.first.last.end_with?("scored at round 1: 10, round 2: 1, round 3: 1, scout: 1"), pairs.first.last

    read = register.merge("synthetic w-flat model-a" => { "compose_steps@r1 members=4" => 3 })
    error = assert_raises(S::Refused) { R.call(definition: definition, trees: trees, command: answer.(read)) }
    assert_includes error.message, "differs from the register on 1 of 13"
    assert_includes error.message, "synthetic w-flat model-a: registered {\"compose_flat@r1 members=0\" => 1}"

    broken = ->(_argv, chdir:) { ["", false, "NameError: uninitialized constant E2E::TaskBench::Door"] }
    error = assert_raises(S::Refused) { R.call(definition: definition, trees: trees, command: broken) }
    assert_includes error.message, "the door reader could not run in /trees/with: NameError"
  end

  # THE TASK BENCH'S OWN DOOR over the tracked corpus reads exactly the register the step gates on.
  def test_the_task_benchs_door_reads_the_register
    door = ->(calls, declared) { E2E::TaskBench::Objectives.door(calls, declared: declared) }
    assert_equal register, R.tally(S::Corpus.door_records, door: door, declared: R.declared)
  end

  private

    def record(task, rounds) = { "bench" => "synthetic", "task" => task.sub("t-", "task-"), "model" => "fixture/model-a", "rounds" => rounds }

    def call(name, input) = { "name" => name, "input" => input }
end
