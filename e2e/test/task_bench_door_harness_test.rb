$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "digest"
require "json"
require "minitest/autorun"
require "support/task_bench"

class TaskBenchDoorHarnessTest < Minitest::Test
  Door = E2E::TaskBench::Door
  Objectives = E2E::TaskBench::Objectives
  DeclaredSet = E2E::TaskBench::DeclaredSet

  def call(name, **arguments) = { "id" => "c", "name" => name, "arguments" => JSON.generate(arguments) }

  def declared(style = "nexus") = DeclaredSet.function_definitions(style: style)

  def door(*raw, style: "nexus")
    set = declared(style)
    Door.kind(raw.map { |one| Objectives::Call.from(one, set) })
  end

  def test_a_message_has_the_door_its_calls_spell
    assert_equal({ kind: "task_fan", members: 2, beside: [] },
      door(call("delegate_task", prompt: "a"), call("delegate_task", prompt: "b")).to_h)
    assert_equal({ kind: "task_one", members: 1, beside: ["bash"] },
      door(call("delegate_task", prompt: "Run ruby test/all.rb"), call("bash", command: "ls lib | wc -l")).to_h)
    assert_equal "spawn", door(call("spawn", prompt: "Keep the suite green.")).kind
    assert_equal ["start_process", ["bash"]],
      door(call("start_process", command: "ruby test/all.rb"), call("bash", command: "ls lib")).to_h.values_at(:kind, :beside)
    assert_equal ["plain", %w[bash read]],
      door(call("bash", command: "ruby test/all.rb"), call("read", path: "lib/a.rb")).to_h.values_at(:kind, :beside)
    assert_equal ["none", []], door.to_h.values_at(:kind, :beside), "a message with no call answered"

    assert_equal ["task_fan", 2], door(call("Agent", prompt: "a"), call("Agent", prompt: "b"), style: "claude").to_h.values_at(:kind, :members)
    assert_equal "spawn", door(call("spawn_agent", prompt: "Keep the suite green."), style: "codex").kind
    assert_equal "task_one", door(call("delegate_task", prompt: "a"), style: "codex").kind
  end

  # EVERY OBJECTIVE'S SCORE CARRIES THE DOOR, so a control's over-reach reads on the same scale as
  # a door objective's choice.
  def test_every_objective_scores_the_door_beside_its_own_properties
    greps = Objectives::CONFIGS.map { |path| call("grep", pattern: "debug: true", path: path) }
    control = Objectives::CONTROL.score(greps, declared: declared)
    assert_equal ["plain", 0, %w[grep]], control.values_at("door_kind", "members", "beside")
    assert control["pass"]
    over = Objectives.find("G0").score([call("delegate_task", prompt: "Review")], declared: declared)
    assert_equal ["task_one", 1], over.values_at("door_kind", "members")
    Objectives::ALL.each do |objective|
      scored = objective.score([], declared: declared)
      assert_equal %w[door_kind members beside], scored.keys.first(3), objective.id
    end
  end

  # THE FOUR DOOR OBJECTIVES, ASCII ids (they travel through the environment and directory names):
  # their texts byte for byte, scored on the first message that is not all reads.
  TEXTS = {
    "D1P" => [740, "f4f668aa907d39b3fa27905c6df2841aace873c7b20eb21f64d8a02ff49c46b6"],
    "D2P" => [325, "331ea90f13233b716b6262d9308a25c41ac1435caf897583de2998b6b52643de"],
    "D4P" => [246, "c938288dbe07721cf0297443cd6728808b8d5010716e51527e5cbc11c0133cb1"],
    "D3P" => [292, "b6bce9879e23d9d987e9911c9e2b3949aecc443c867a29bdb1c27de2b3b92b84"],
  }.freeze

  def test_the_door_objectives_are_registered_with_their_texts_byte_for_byte
    assert_equal TEXTS.keys, Objectives.ids.last(4)
    TEXTS.each do |id, (bytes, sha)|
      objective = Objectives.find(id)
      assert_equal [bytes, sha], [objective.text.bytesize, Digest::SHA256.hexdigest(objective.text)], id
      refute objective.scored_first, id
      assert id.ascii_only?, id
    end
  end

  # THE FIXTURES ARE THE PREMISES: every file a text names, D4P's nine sources under lib/ beside the
  # suite it names, and D3P's five files each defining exactly one method that nothing under lib/
  # calls.
  def test_the_fixtures_hold_the_premises_their_texts_state
    assert_equal %w[lib/balance.rb lib/ledger.rb lib/posting.rb], Objectives.find("D1P").fixture.keys
    assert_equal %w[docs/date_format.md lib/fmt_a.rb lib/fmt_b.rb], Objectives.find("D2P").fixture.keys
    job = Objectives.find("D4P").fixture
    assert_equal 9, job.keys.count { |path| path.start_with?("lib/") && path.end_with?(".rb") }
    assert_equal ["test/all.rb"], job.keys.grep(%r{\Atest/})
    assert_equal 10, job.size

    five = Objectives.find("D3P").fixture
    lib = five.select { |path, _| path.start_with?("lib/") }.values.join("\n")
    unused = %w[a b c d e].to_h do |name|
      defined = five.fetch("lib/#{name}.rb").scan(/def self\.(\w+)/).flatten
      [name, defined.select { |method| lib.scan(/(?<!def self)\.#{method}\b/).empty? }]
    end
    unused.each { |name, methods| assert_equal 1, methods.length, "lib/#{name}.rb: #{methods.inspect}" }
  end

  def test_fan_objectives_require_their_number_of_tasks
    { "D1P" => 6, "D2P" => 3, "D3P" => 5 }.each do |id, size|
      objective = Objectives.find(id)
      tasks = Array.new(size) { |i| call("delegate_task", prompt: "Review item #{i + 1}.") }
      assert_equal [true, true, false], objective.score(tasks, declared: declared).values_at("pass", "right_door", "acceptable_door")
      refute objective.score(tasks.first(size - 1), declared: declared)["right_door"]
    end
  end

  def test_d4p_takes_one_background_task_naming_the_suite
    d4p = Objectives.find("D4P")
    count = call("bash", command: "ls lib | wc -l")
    right = d4p.score([call("delegate_task", prompt: "Run the full suite: ruby test/all.rb. Report failures."), count], declared: declared)
    assert_equal [true, true, ["bash"]], right.values_at("pass", "right_door", "beside")
    assert d4p.score([call("Agent", prompt: "Run ruby test/all.rb and report.")], declared: declared("claude"))["right_door"]

    {
      "a waited task" => [call("delegate_task", prompt: "Run ruby test/all.rb.", wait: true)],
      "a task that names no suite" => [call("delegate_task", prompt: "Count the Ruby files under lib/.")],
      "a process beside it" => [call("delegate_task", prompt: "Run ruby test/all.rb."), call("start_process", command: "ruby test/all.rb")],
      "running it itself" => [call("bash", command: "ruby test/all.rb")],
      "two tasks" => [call("delegate_task", prompt: "Run ruby test/all.rb."), call("delegate_task", prompt: "Count lib/.")],
    }.each { |label, calls| refute d4p.score(calls, declared: declared)["right_door"], label }
  end
end
