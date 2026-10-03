$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "digest"
require "json"
require "minitest/autorun"
require "support/task_bench"

# THE DOOR A SCORED MESSAGE WENT THROUGH, before any money is spent: a kind for every message, read
# from the calls as the kernel resolves them. A compose call's script is built by the shipped
# evaluator under the round's declared names, refused by the kernel's lowering where it would be,
# its result-free stages inlined, and its model leaves read as `Nexus::Compose::Reads` reads them:
# `members` are the model leaves a later step reads, `unread` what comes back to the caller. The
# four door objectives score their right door on that reading, over fixtures that hold every file
# their texts name.
class TaskBenchDoorHarnessTest < Minitest::Test
  Door = E2E::TaskBench::Door
  Objectives = E2E::TaskBench::Objectives
  DeclaredSet = E2E::TaskBench::DeclaredSet

  PANEL = <<~JS.freeze
    const lenses = ["data loss", "locking", "rollback"];
    const reviews = g.parallel(lenses.map((lens) => g.model({ prompt: "Read db/migrate/20260927_split_accounts.rb. Through the " + lens + " lens only: is it safe to run on production? Answer `ship` or `hold` and the one risk that decides it." })));
    g.model({ prompt: "Weigh the three reviews; answer `ship` or `hold` and the deciding risk.", results: reviews });
  JS
  # A judge panel as a strong model writes one in vivo: three judges, and a chair that names none of them.
  CHAIR = <<~JS.freeze
    const judge = () => g.model({ prompt: "You are an independent judge. Score each candidate 0-10." });
    const js = g.parallel([judge(), judge(), judge()]);
    g.model({ prompt: "You are the chair. Tally the three judges' scores and name the winner.", tools: [] });
  JS
  # Six claims, a chain per claim: two disprovers, then a reader of the pair.
  CHAINS = <<~JS.freeze
    const claims = ["C1", "C2", "C3", "C4", "C5", "C6"];
    g.parallel(claims.map((claim) => {
      const a = g.model({ prompt: "Try to disprove " + claim + " from the code." });
      const b = g.model({ prompt: "Try again, independently, to disprove " + claim + "." });
      return [a, b, g.model({ prompt: claim + " is sound only if both failed: sound or broken?", results: [a, b] })];
    }));
  JS

  def call(name, **arguments) = { "id" => "c", "name" => name, "arguments" => JSON.generate(arguments) }

  def compose(script) = call("compose", script: script)

  def declared(style = "nexus") = DeclaredSet.function_definitions(style: style)

  def door(*raw, style: "nexus")
    set = declared(style)
    Door.kind(raw.map { |one| Objectives::Call.from(one, set) }, declared: set)
  end

  # A PANEL: three model leaves one reader names — read, and the reader, which names its results,
  # is what comes back. A chair that names none of its judges starts from its prompt alone, so the
  # four come back unread: a fan with no reader, `compose_flat`.
  def test_a_panel_with_a_reader_is_compose_steps_and_a_chair_naming_no_judge_is_flat
    assert_equal({ kind: "compose_steps", built: true, members: 3, unread: ["model-4"], beside: [] }, door(compose(PANEL)).to_h)

    chair = door(compose(CHAIR))
    assert_equal ["compose_flat", true, 0], [chair.kind, chair.built, chair.members]
    assert_equal %w[model-1 model-2 model-3 model-4], chair.unread

    dangling = door(compose("#{PANEL}g.model({ prompt: \"Summarise the work so far.\" });"))
    assert_equal ["compose_flat", 3], [dangling.kind, dangling.members], "a summariser that reads nothing leaves the plan flat"

    raced = door(compose(<<~JS))
      const race = g.parallel(["a", "b", "c"].map((lens) => g.model({ prompt: "Answer through " + lens })), { until: "any" });
      g.model({ prompt: "Take the first answer.", results: [race] });
    JS
    assert_equal ["compose_steps", 3, ["model-4"]], [raced.kind, raced.members, raced.unread],
      "a race's exits are read where its barrier is named"
  end

  # A READ OF A RACE IS A READ OF ITS EXITS, as the lowering reads it (`Shape.race_reads`): an arm
  # that is a chain hands its reader the chain's last leaf, a stage ending an arm its final leaf,
  # and what stands before either is read by nothing — placed in the race's arms, it never comes
  # back either.
  def test_a_race_is_read_by_its_exits_and_not_by_every_leaf_in_its_arms
    chained = door(compose(<<~JS))
      const race = g.parallel(["x", "y"].map((k) => [g.model({ prompt: "Draft " + k }), g.model({ prompt: "Polish " + k })]), { until: "any" });
      g.model({ prompt: "Pick the better one.", results: [race] });
    JS
    assert_equal({ kind: "compose_steps", built: true, members: 2, unread: ["model-5"], beside: [] }, chained.to_h)

    staged = door(compose(<<~JS))
      const race = g.parallel(["x", "y"].map((k) => g.script({ script: "g.model({ prompt: 'Draft " + k + "' }); g.model({ prompt: 'Polish " + k + "' });" })), { until: "any" });
      g.model({ prompt: "Pick the better one.", results: [race] });
    JS
    assert_equal({ kind: "compose_steps", built: true, members: 2, unread: ["model-1"], beside: [] }, staged.to_h)
  end

  # EVERY UNREAD LEAF NAMING ITS RESULTS IS NOT ENOUGH: twelve disprovers each fed the code by
  # `results:` and read by nothing are a fan with no reader — no model leaf is read, members 0.
  def test_a_tool_fed_fan_that_nothing_reads_is_flat_with_no_members
    fan = door(compose(<<~JS))
      const code = g.tool({ name: "read", input: { path: "lib/ledger.rb" } });
      g.parallel(Array.from({ length: 12 }, (_, i) => g.model({ prompt: "Disprove claim C" + (i % 6 + 1), results: [code] })));
    JS
    assert_equal ["compose_flat", true, 0], [fan.kind, fan.built, fan.members]
    assert_equal 12, fan.unread.length
    refute_includes fan.unread, "tool-1", "the code is read by every disprover"
  end

  def test_a_chain_per_claim_is_compose_steps_with_every_disprover_read
    chains = door(compose(CHAINS))
    assert_equal ["compose_steps", 12], [chains.kind, chains.members]
    assert_equal %w[model-3 model-6 model-9 model-12 model-15 model-18], chains.unread, "each chain's reader comes back"
  end

  # A RESULT-FREE STAGE IS INLINED, its keys under its own: what it places before its final leaf
  # is internal and never comes back, however deep the stage sits; only the final leaf crosses.
  def test_a_stage_wrapped_panel_is_inlined_and_only_its_final_leaf_comes_back
    wrapped = door(compose(<<~JS))
      g.script({ script: `
        g.tool({ name: "bash", input: { command: "git log -1" } });
        const reviews = g.parallel(["a", "b", "c"].map((lens) => g.model({ prompt: "Review through " + lens })));
        g.model({ prompt: "Weigh them.", results: reviews });
      ` });
    JS
    assert_equal({ kind: "compose_steps", built: true, members: 3, unread: ["script-1/model-4"], beside: [] }, wrapped.to_h)

    nested = door(compose(<<~JS))
      g.script({ script: `
        g.script({ script: "g.tool({ name: 'bash', input: { command: 'ls' } });" });
        g.model({ prompt: "Say done." });
      ` });
    JS
    assert_equal ["compose_flat", ["script-1/model-1"]], [nested.kind, nested.unread],
      "a nested stage's final leaf is internal to the stage around it"
  end

  # A PLAN NO TEXT CAN KNOW, OR NO MODEL: a stage that reads results holds its shape in a body the
  # builder cannot see; tools alone are a pipeline, and waits over tasks already running are a
  # gather.
  def test_the_plans_without_a_model_reader_each_have_their_kind
    opaque = door(compose(<<~JS))
      const files = g.tool({ name: "bash", input: { command: "ls lib" } });
      g.script({ results: [files], script: "results[0].output.split(' ').forEach((f) => g.model({ prompt: 'Review ' + f }));" });
    JS
    assert_equal "compose_opaque", opaque.kind

    tools = door(compose('["a", "b", "c", "d", "e", "f", "g"].forEach((d) => g.tool({ name: "bash", input: { command: "ls " + d } }));'))
    assert_equal ["compose_tools", 7], [tools.kind, tools.unread.length]

    gather = door(compose(<<~JS))
      const got = g.parallel([g.wait({ task: "r3t0" }), g.wait({ task: "r5t0" }), g.wait({ task: "r7t0" })]);
      g.script({ after: got, script: "return 'collated';" });
    JS
    assert_equal "compose_gather", gather.kind

    one = door(compose('g.tool({ name: "bash", input: { command: "ruby test/all.rb" } });'), call("bash", command: "ls lib"))
    assert_equal({ kind: "compose_one", built: true, members: 0, unread: ["tool-1"], beside: ["bash"] }, one.to_h)
  end

  # A SCRIPT THE KERNEL REFUSES builds nothing: the evaluator's refusal — a script that places no
  # step among them, whatever it returns, since only a stage answers with a value — the lowering's
  # under the round's own names, and arguments no JSON parser reads are all `compose_refused`,
  # never a raise.
  def test_a_refused_script_is_compose_refused_and_never_raises
    returned = Nexus::Compose::Evaluator.call(script: "return { verdict: \"nothing to run\" };", tool_names: %w[bash])
    assert_equal [:script_error, Nexus::Compose::Evaluator::NO_STEP], [returned.refusal, returned.detail]
    [
      compose("return { verdict: \"nothing to run\" };"),
      compose('g.tool({ name: "bash" '),
      compose('g.tool({ name: "deploy", input: {} });'),
      compose("const runs = [g.model({ prompt: \"a\" })]; g.model({ prompt: \"b\", results: [runs] });"),
      { "id" => "c", "name" => "compose", "arguments" => "{not json" },
    ].each do |raw|
      refused = door(raw)
      assert_equal({ kind: "compose_refused", built: false, members: 0, unread: [], beside: [] }, refused.to_h, raw["arguments"])
    end
  end

  # WITHOUT A COMPOSE CALL the door is the delegation the message holds, under any spelling the set
  # declares: `Agent` is a task, `spawn_agent` a spawn.
  def test_a_message_without_compose_has_the_door_its_calls_spell
    assert_equal({ kind: "task_fan", built: nil, members: 2, unread: [], beside: [] },
      door(call("task", prompt: "a"), call("task", prompt: "b")).to_h)
    assert_equal({ kind: "task_one", built: nil, members: 1, unread: [], beside: ["bash"] },
      door(call("task", prompt: "Run ruby test/all.rb"), call("bash", command: "ls lib | wc -l")).to_h)
    assert_equal "spawn", door(call("spawn", prompt: "Keep the suite green.")).kind
    assert_equal ["start_process", ["bash"]],
      door(call("start_process", command: "ruby test/all.rb"), call("bash", command: "ls lib")).to_h.values_at(:kind, :beside)
    assert_equal ["plain", %w[bash read]],
      door(call("bash", command: "ruby test/all.rb"), call("read", path: "lib/a.rb")).to_h.values_at(:kind, :beside)
    assert_equal ["none", []], door.to_h.values_at(:kind, :beside), "a message with no call answered"

    assert_equal ["task_fan", 2], door(call("Agent", prompt: "a"), call("Agent", prompt: "b"), style: "claude").to_h.values_at(:kind, :members)
    assert_equal "compose_steps", door(compose(PANEL), style: "claude").kind
    assert_equal "spawn", door(call("spawn_agent", prompt: "Keep the suite green."), style: "codex").kind
    assert_equal "task_one", door(call("task", prompt: "a"), style: "codex").kind
  end

  # EVERY OBJECTIVE'S SCORE CARRIES THE DOOR, so a control's over-reach reads on the same scale as
  # a door objective's choice.
  def test_every_objective_scores_the_door_beside_its_own_properties
    greps = Objectives::CONFIGS.map { |path| call("grep", pattern: "debug: true", path: path) }
    control = Objectives::CONTROL.score(greps, declared: declared)
    assert_equal ["plain", nil, 0, [], %w[grep]], control.values_at("door_kind", "built", "members", "unread", "beside")
    assert control["pass"]
    over = Objectives.find("G0").score([compose(PANEL)], declared: declared)
    assert_equal ["compose_steps", 3], over.values_at("door_kind", "members")
    Objectives::ALL.each do |objective|
      scored = objective.score([], declared: declared)
      assert_equal %w[door_kind built members unread beside], scored.keys.first(5), objective.id
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

  # D1P: a compose call whose six claims' disprovers — at least six model leaves — are read by later
  # steps; a task fan of six beside it as the acceptable door; a fan nothing reads is the wrong one.
  def test_d1p_takes_a_read_fan_of_six_and_accepts_six_tasks
    d1p = Objectives.find("D1P")
    right = d1p.score([compose(CHAINS)], declared: declared)
    assert_equal [true, true, false], right.values_at("pass", "right_door", "acceptable_door")
    flat = d1p.score([compose("const code = g.tool({ name: \"read\", input: { path: \"lib/ledger.rb\" } });\n" \
                              "g.parallel([1, 2, 3, 4, 5, 6].map((n) => g.model({ prompt: \"Disprove C\" + n, results: [code] })));")],
      declared: declared)
    assert_equal ["compose_flat", false], flat.values_at("door_kind", "right_door")
    refute d1p.score([compose(PANEL)], declared: declared)["right_door"], "three read leaves are not six"

    six = d1p.score(Array.new(6) { |i| call("task", prompt: "Disprove C#{i + 1}") }, declared: declared)
    assert_equal [false, false, true], six.values_at("pass", "right_door", "acceptable_door")
    refute d1p.score(Array.new(5) { |i| call("task", prompt: "Disprove C#{i + 1}") }, declared: declared)["acceptable_door"]
  end

  def test_d2p_takes_a_read_panel_of_three_and_accepts_three_tasks
    d2p = Objectives.find("D2P")
    assert d2p.score([compose(PANEL)], declared: declared)["right_door"]
    refute d2p.score([compose(CHAIR)], declared: declared)["right_door"], "the chair reads none of the scorers"
    three = d2p.score(Array.new(3) { call("task", prompt: "Score fmt_a and fmt_b against docs/date_format.md.") }, declared: declared)
    assert_equal [false, true], three.values_at("right_door", "acceptable_door")
  end

  # D4P: one background `task` naming the suite; no process started beside it, no compose, no
  # waited task. The count beside it is a fact, never the door.
  def test_d4p_takes_one_background_task_naming_the_suite
    d4p = Objectives.find("D4P")
    count = call("bash", command: "ls lib | wc -l")
    right = d4p.score([call("task", prompt: "Run the full suite: ruby test/all.rb. Report failures."), count], declared: declared)
    assert_equal [true, true, ["bash"]], right.values_at("pass", "right_door", "beside")
    assert d4p.score([call("Agent", prompt: "Run ruby test/all.rb and report.")], declared: declared("claude"))["right_door"]

    {
      "a waited task" => [call("task", prompt: "Run ruby test/all.rb.", wait: true)],
      "a task that names no suite" => [call("task", prompt: "Count the Ruby files under lib/.")],
      "a process beside it" => [call("task", prompt: "Run ruby test/all.rb."), call("start_process", command: "ruby test/all.rb")],
      "a one-step compose" => [compose('g.tool({ name: "bash", input: { command: "ruby test/all.rb" } });')],
      "running it itself" => [call("bash", command: "ruby test/all.rb")],
      "two tasks" => [call("task", prompt: "Run ruby test/all.rb."), call("task", prompt: "Count lib/.")],
    }.each { |label, calls| refute d4p.score(calls, declared: declared)["right_door"], label }
  end

  # D3P: five finders handed out at once — five tasks, or a compose whose five finders a later step
  # reads, the compose share recorded on its own.
  def test_d3p_takes_five_tasks_or_a_read_compose_of_five
    d3p = Objectives.find("D3P")
    tasks = d3p.score(%w[a b c d e].map { |x| call("task", prompt: "Find the unused method in lib/#{x}.rb.") }, declared: declared)
    assert_equal [true, false], tasks.values_at("right_door", "compose_door")
    gathered = d3p.score([compose(<<~JS)], declared: declared)
      const finds = g.parallel(["a", "b", "c", "d", "e"].map((x) => g.model({ prompt: "Find the unused method in lib/" + x + ".rb." })));
      g.model({ prompt: "One line per file: lib/<x>.rb — <method>.", results: finds });
    JS
    assert_equal [true, true, 5], gathered.values_at("right_door", "compose_door", "members")
    refute d3p.score(%w[a b c d].map { |x| call("task", prompt: "lib/#{x}.rb") }, declared: declared)["right_door"]
  end
end
