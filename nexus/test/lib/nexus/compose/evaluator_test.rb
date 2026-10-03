require "test_helper"

# The evaluator runs a model-authored PURE function in an isolate that
# grants nothing. These pin the two halves that matter: that a script
# places the step tree the loop needs, in written order, and that every
# way a script can misbehave comes back at its line as a sentence that
# names the repair, never as damage and never as a silent drop.
class Nexus::Compose::EvaluatorTest < ActiveSupport::TestCase
  Evaluator = Nexus::Compose::Evaluator

  def build(script, params = {}, tool_names: %w[read_file bash])
    Evaluator.call(script: script, params: params, tool_names: tool_names)
  end

  # The isolate prefixes a thrown Error's message with its class; the
  # sentence is what the model reads after it.
  def refusal(script, **options)
    result = build(script, **options)
    assert_equal :script_error, result.refusal, result.inspect
    result.detail.delete_prefix("Error: ")
  end

  test "a fan of tool steps and a model step that reads them, in written order" do
    result = build(<<~JS, { "paths" => %w[a.rb b.rb c.rb] })
      const reads = params.paths.map(path =>
        g.tool({ name: "read_file", input: { path } })
      );
      g.parallel(reads);
      g.model({ prompt: "summarize these" });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal [
      { "parallel" => [
        { "tool" => { "key" => "tool-1", "name" => "read_file", "input" => { "path" => "a.rb" } } },
        { "tool" => { "key" => "tool-2", "name" => "read_file", "input" => { "path" => "b.rb" } } },
        { "tool" => { "key" => "tool-3", "name" => "read_file", "input" => { "path" => "c.rb" } } },
      ] },
      { "model" => { "key" => "model-1", "prompt" => "summarize these" } },
    ], result.steps
    assert_equal [{ "line" => 4, "members" => [2, 2, 2] }, 5], result.lines,
      "the group carries the line that grouped and each member's own"
  end

  test "a race and a quorum spell until on the group, and the group returns a real array" do
    result = build(<<~JS, { "n" => 3 })
      const a = g.model({ prompt: "approach A" });
      const b = g.model({ prompt: "approach B" });
      const race = g.parallel([a, b], { until: "any" });
      const reviewers = [];
      for (let i = 0; i < params.n; i++) reviewers.push(g.model({ prompt: `review ${i}` }));
      const quorum = g.parallel(reviewers, { until: 2 });
      g.model({ prompt: "reduce: " + race.length + " raced, " + quorum.length + " reviewed" });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal ["any", 2], result.steps.first(2).map { |step| step["until"] }
    assert_equal %w[model-1 model-2], result.steps[0]["parallel"].map { |m| m["model"]["key"] }
    assert_equal "reduce: 2 raced, 3 reviewed", result.steps.last.dig("model", "prompt")
  end

  # A RACE IS ONE STEP A LATER STEP MAY NAME: the Array its g.parallel returned, in `after:` or
  # `results:`, crosses as the key the builder minted on the race — the name the kernel's barrier is
  # placed under, and the only one a reference can carry — so a reader waits on the barrier and
  # reads what the race selected, never a member it would keep alive.
  test "a race's handle in results and after crosses as the key the builder minted on the race" do
    result = build(<<~JS)
      const fast = g.tool({ name: "read_file", input: { path: "fast" } });
      const slow = g.tool({ name: "read_file", input: { path: "slow" } });
      const race = g.parallel([fast, slow], { until: "any" });
      g.script({ results: [race], script: "return results[0].output;" });
      g.tool({ name: "read_file", input: { path: "after" }, after: [race] });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal({ "parallel" => [{ "tool" => { "key" => "tool-1", "name" => "read_file", "input" => { "path" => "fast" } } },
                                  { "tool" => { "key" => "tool-2", "name" => "read_file", "input" => { "path" => "slow" } } }],
                   "until" => "any", "key" => "parallel-1" }, result.steps.first)
    assert_equal ["parallel-1"], result.steps[1].dig("script", "results")
    assert_equal ["parallel-1"], result.steps[2].dig("tool", "after")
  end

  # THE BUILDER MINTS EVERY RACE'S KEY AND NEVER TAKES ONE: a script writes no key on a g.parallel
  # (`unknownOption`, the one option is until), a quorum is a race too, an "all" group places no
  # barrier and carries none, a leaf the model keyed `parallel-1` moves the race to the next free
  # name, and races are numbered in the order their g.parallel ran — an inner race first.
  test "the builder mints a race's key, skipping a name the script took, and an all group carries none" do
    result = build(<<~JS)
      const taken = g.tool({ name: "read_file", key: "parallel-1" });
      const a = g.tool({ name: "read_file" });
      const b = g.tool({ name: "read_file" });
      const inner = g.parallel([a, b], { until: 1 });
      const c = g.tool({ name: "read_file" });
      g.parallel([[inner], c], { until: "any" });
      g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })]);
      g.model({ prompt: "p" });
    JS

    assert_predicate result, :built?, result.inspect
    outer = result.steps[1]
    assert_equal "parallel-3", outer["key"], "the outer race's g.parallel ran second"
    assert_equal "parallel-2", outer["parallel"].first.sole["key"], "the inner race's ran first, past the name the script took"
    refute result.steps[2].key?("key"), "an all group places no barrier and carries no key"
    assert_includes refusal('g.parallel([g.tool({ name: "read_file" })], { until: "any", key: "mine" });'),
      %(g.parallel: unknown option "key". The one option is until.)
    assert_includes refusal(<<~JS), "duplicate task key: parallel-1"
      g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })], { until: "any" });
      g.tool({ name: "read_file", key: "parallel-1" });
    JS
  end

  # WHAT A REFERENCE CANNOT NAME, each with the repair: the race itself as the list (it would name
  # every member), an "all" group (no one step), a list nested in the list (the array a `.map`
  # built is already the list of handles), and anything that is not a handle.
  test "a reference refuses a race written as the list, an all group, a nested list, and anything but a handle" do
    race = 'const race = g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })], { until: "any" });'
    assert_equal "g.script: results takes a list; write results: [race] to name the race, not results: race.",
      refusal("#{race}\ng.script({ results: race, script: \"return null;\" });")
    assert_equal "g.tool: after takes a list; write after: [race] to name the race, not after: race.",
      refusal("#{race}\ng.tool({ name: \"read_file\", after: race });")
    assert_equal %(g.model: results names an "all" group, which is not one step; list its steps instead: results: [a, b].),
      refusal(<<~JS)
        const group = g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })]);
        g.model({ prompt: "p", results: [group] });
      JS
    runs = 'const runs = ["a", "b"].map((path) => g.tool({ name: "read_file", input: { path } }));'
    assert_equal "g.model: results: [runs] nests a list; write results: runs — the array itself is the list of handles.",
      refusal("#{runs}\ng.parallel(runs);\ng.model({ prompt: \"p\", results: [runs] });")
    assert_equal "g.tool: after: [runs] nests a list; write after: runs — the array itself is the list of handles.",
      refusal("#{runs}\ng.tool({ name: \"read_file\", after: [runs] });")
    named = build("#{runs}\ng.parallel(runs);\ng.model({ prompt: \"p\", results: runs });")
    assert_predicate named, :built?, "the array itself is the list: #{named.detail}"
    assert_equal %w[tool-1 tool-2], named.steps.last.dig("model", "results")
    assert_equal "g.model: results accepts leaf handles and races, not result values or string keys; " \
                 "pass the handle a builder returned: results: [a].",
      refusal('g.tool({ name: "read_file" }); g.model({ prompt: "p", results: ["tool-1"] });')
    assert_equal "g.tool: after accepts leaf handles and races, not result values or string keys; " \
                 "pass the handle a builder returned: after: [a].",
      refusal('g.tool({ name: "read_file" }); g.tool({ name: "read_file", after: [{ key: "tool-1" }] });')
  end

  # A CHAIN IS NOT A STEP: for a member written as a nested sequence or a function, the list a
  # g.parallel returns holds that member's chain. Named whole, each entry is a chain, and the
  # nested-list repair would tell the author to write what they wrote — so the refusal names each
  # chain's last step, from either kind of member, for a chain of one step, for the member arrays
  # the script wrote itself, and on every verb.
  test "naming the chains a g.parallel returned is refused with the last-step repair" do
    pairs = <<~JS
      const out = g.parallel(["a", "b"].map((path) => [
        g.tool({ name: "read_file", input: { path } }),
        g.model({ prompt: "Summarize " + path }),
      ]));
    JS
    functions = <<~JS
      const out = g.parallel(["a", "b"].map((path) => () => {
        const read = g.tool({ name: "read_file", input: { path } });
        g.model({ prompt: "Summarize " + path, results: [read] });
      }));
    JS
    singles = %(const out = g.parallel(["a", "b"].map((path) => [g.tool({ name: "read_file", input: { path } })]));\n)
    own = <<~JS
      const out = ["a", "b"].map((path) => {
        const read = g.tool({ name: "read_file", input: { path } });
        return [read, g.model({ prompt: "Summarize " + path, results: [read] })];
      });
      g.parallel(out);
    JS
    reader = 'g.model({ prompt: "p", results: out });'
    sentence = "g.model: results: an entry is a chain [a, b], not a step; name each chain's last step: " \
               "results: chains.map((c) => c[c.length - 1])."
    assert_equal sentence, refusal(pairs + reader), "array members"
    assert_equal sentence, refusal(functions + reader), "function members"
    assert_equal sentence, refusal(singles + reader), "one-step chains"
    assert_equal sentence, refusal(own + reader), "the member arrays the script wrote"
    assert_equal "g.tool: after: an entry is a chain [a, b], not a step; name each chain's last step: " \
                 "after: chains.map((c) => c[c.length - 1]).",
      refusal(pairs + 'g.tool({ name: "read_file", after: out });')
    assert_equal "g.script: results: an entry is a chain [a, b], not a step; name each chain's last step: " \
                 "results: chains.map((c) => c[c.length - 1]).",
      refusal(pairs + 'g.script({ results: out, script: "return null;" });')
  end

  # The last-step repair builds; a chain that ends on an "all" group has no last step a reference
  # may name, so its sentence names the group's members instead, while a chain ending on a race —
  # one step — keeps the repair; and a list nested in the list, which no g.parallel returned, keeps
  # its own sentence.
  test "the last-step repair builds, a chain ending on a group names its members, and a nested list is unchanged" do
    pairs = <<~JS
      const out = g.parallel(["a", "b"].map((path) => [
        g.tool({ name: "read_file", input: { path } }),
        g.model({ prompt: "Summarize " + path }),
      ]));
    JS
    repair = 'g.model({ prompt: "p", results: out.map((c) => c[c.length - 1]) });'
    repaired = build(pairs + repair)
    assert_predicate repaired, :built?, repaired.inspect
    assert_equal %w[model-1 model-2], repaired.steps.last.dig("model", "results")
    own = <<~JS
      const out = ["a", "b"].map((path) => {
        const read = g.tool({ name: "read_file", input: { path } });
        return [read, g.model({ prompt: "Summarize " + path, results: [read] })];
      });
      g.parallel(out);
    JS
    owned = build(own + repair)
    assert_predicate owned, :built?, owned.inspect
    assert_equal %w[model-1 model-2], owned.steps.last.dig("model", "results")

    ending = <<~JS
      const out = g.parallel(["a", "b"].map((path) => [
        g.tool({ name: "read_file", input: { path } }),
        g.parallel([g.model({ prompt: "Check " + path }), g.model({ prompt: "Test " + path })]),
      ]));
    JS
    grouped = "g.model: results: an entry is a chain [a, b], not a step; the chain ends on a group; " \
              "name that group's members' last steps instead."
    assert_equal grouped, refusal(ending + 'g.model({ prompt: "p", results: out });')
    assert_equal grouped, refusal(<<~JS), "whichever chain of the list ends on the group"
      const steps = g.parallel([[g.tool({ name: "read_file", input: { path: "a" } }), g.model({ prompt: "Check a" })]]);
      #{ending}g.model({ prompt: "p", results: [...steps, ...out] });
    JS
    race = <<~JS
      const out = g.parallel(["a", "b"].map((path) => [
        g.tool({ name: "read_file", input: { path } }),
        g.parallel([g.model({ prompt: "Check " + path }), g.model({ prompt: "Test " + path })], { until: "any" }),
      ]));
    JS
    assert_includes refusal(race + 'g.model({ prompt: "p", results: out });'),
      "name each chain's last step: results: chains.map((c) => c[c.length - 1]).", "a race is one step"
    raced = build(race + repair)
    assert_predicate raced, :built?, raced.inspect
    assert_equal %w[parallel-1 parallel-2], raced.steps.last.dig("model", "results")

    runs = %(const runs = ["a", "b"].map((path) => g.tool({ name: "read_file", input: { path } }));\ng.parallel(runs);\n)
    assert_equal "g.model: results: [runs] nests a list; write results: runs — the array itself is the list of handles.",
      refusal(runs + 'g.model({ prompt: "p", results: [runs] });')
    named = build(runs + 'g.model({ prompt: "p", results: runs });')
    assert_predicate named, :built?, named.inspect
    assert_equal %w[tool-1 tool-2], named.steps.last.dig("model", "results")
  end

  # A group may hold a chain beside a single step — `g.parallel([[read, review], other])`, the
  # compose text's own way to keep a chain from waiting on unrelated work — and then its array
  # holds a chain and a step, which no one expression over the array tells apart from a group or a
  # race: the refusal asks for each chain's last step in its place, whichever entry comes first,
  # and that list builds.
  test "naming a group that mixes chains and steps is refused with each chain's last step in its place" do
    mixed = <<~JS
      const read = g.tool({ name: "read_file", input: { path: "a" } });
      const review = g.model({ prompt: "Review a", results: [read] });
      const other = g.tool({ name: "read_file", input: { path: "b" } });
      const both = g.parallel([[read, review], other]);
    JS
    sentence = "g.model: results: an entry is a chain [a, b], not a step; name each chain's last step in its place: " \
               "results: [review, other] for g.parallel([[read, review], other])."
    assert_equal sentence, refusal(mixed + 'g.model({ prompt: "p", results: both });')
    assert_equal sentence, refusal(mixed + 'g.model({ prompt: "p", results: [other, both[0]] });'), "the step listed first"
    assert_equal "g.tool: after: an entry is a chain [a, b], not a step; name each chain's last step in its place: " \
                 "after: [review, other] for g.parallel([[read, review], other]).",
      refusal(mixed + 'g.tool({ name: "read_file", after: both });')
    repaired = build(mixed + 'g.model({ prompt: "p", results: [review, other] });')
    assert_predicate repaired, :built?, repaired.inspect
    assert_equal %w[model-1 tool-2], repaired.steps.last.dig("model", "results")
  end

  # A race's barrier is placed after its members, so a group member naming a race listed after it is
  # refused at the line exactly as a leaf listed after it is; a reference written before the race
  # formed — a member reading a peer — is unchanged.
  test "a group member naming a race listed after it is refused with the member-order repair" do
    assert_equal %(g.parallel: "model-1" reads "parallel-1", listed after it; list a step after the steps it reads.),
      refusal(<<~JS)
        const inner = g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })], { until: "any" });
        const reader = g.model({ prompt: "Say which answered.", results: [inner] });
        g.parallel([[reader, inner]]);
      JS

    built = build(<<~JS)
      const inner = g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })], { until: "any" });
      const reader = g.model({ prompt: "Say which answered.", results: [inner] });
      g.parallel([[inner, reader], g.tool({ name: "read_file" })]);
      const a = g.tool({ name: "read_file" });
      const b = g.model({ prompt: "Check it.", results: [a] });
      g.parallel([a, b], { until: "any" });
    JS
    assert_predicate built, :built?, built.inspect
    assert_equal ["parallel-1"], built.steps.first["parallel"].first.last.dig("model", "results")
  end

  # A SCRIPT'S RACE STOPS THE MEMBERS IT DID NOT SELECT, so once a race has formed, a later step
  # naming one of its leaves — at the top level, inside a member function, or in a stage's body — is
  # refused at the line with the race's line, its own `until` and the repair: a reference that waits
  # on a loser silently reverses the race. A reference written before the race formed — a member
  # reading a peer — is unchanged, and the race itself is always named.
  test "a reference to a leaf of a formed race is refused with the repair; one written before it formed is not" do
    race = <<~JS
      const a = g.tool({ name: "read_file", input: { path: "a" } });
      const b = g.tool({ name: "read_file", input: { path: "b" } });
      const race = g.parallel([a, b], { until: "any" });
    JS
    assert_equal %(g.script: results names "tool-1", a member of the race on line 3; a race stops the members it did not ) +
      %(select, so name the race itself: const race = g.parallel([...], { until: "any" }); then results: [race].),
      refusal("#{race}g.script({ results: [a], script: \"return null;\" });")
    assert_includes refusal("#{race}g.tool({ name: \"read_file\", after: [b] });"),
      %(g.tool: after names "tool-2", a member of the race on line 3)
    assert_includes refusal("#{race}g.parallel([() => { g.model({ prompt: \"p\", results: [a] }); }, g.tool({ name: \"read_file\" })]);"),
      %(g.model: results names "tool-1", a member of the race on line 3), "inside a member function"
    assert_includes refusal(race.sub('{ until: "any" }', "{ until: 2 }") + 'g.model({ prompt: "p", results: [b] });'),
      "const race = g.parallel([...], { until: 2 })", "the repair echoes the race's own until"
    staged = Evaluator.stage(script: "#{race}g.script({ results: [a], script: \"return null;\" });", tool_names: %w[read_file])
    assert_equal :script_error, staged.refusal
    assert_includes staged.detail, %(results names "tool-1", a member of the race on line 3), "in a stage's body"

    inner = refusal(<<~JS)
      const x = g.tool({ name: "read_file" });
      const pair = [g.tool({ name: "read_file" }), g.model({ prompt: "p" })];
      g.parallel([x, pair], { until: "any" });
      g.model({ prompt: "q", results: [pair[1]] });
    JS
    assert_includes inner, %(results names "model-1", a member of the race on line 3), "a leaf inside an arm's sequence"

    built = build(<<~JS)
      const a = g.tool({ name: "read_file", input: { path: "a" } });
      const b = g.model({ prompt: "Check it.", results: [a] });
      const race = g.parallel([a, b], { until: "any" });
      g.script({ results: [race], script: "return results[0].output;" });
    JS
    assert_predicate built, :built?, built.inspect
  end

  test "a nested array is a sequence inside the group; a function member builds in its own frame" do
    result = build(<<~JS)
      const a1 = g.tool({ name: "read_file", input: { path: "a" } });
      const b1 = g.model({ prompt: "review a" });
      g.parallel([[a1, b1], () => { g.tool({ name: "read_file", input: { path: "b" } }); g.model({ prompt: "review b" }); }]);
      g.model({ prompt: "combine" });
    JS

    assert_predicate result, :built?, result.inspect
    group = result.steps.first["parallel"]
    assert_equal [%w[tool-1 model-1], %w[tool-2 model-2]],
      group.map { |member| member.map { |step| step.values.first["key"] } }
    assert_equal [[1, 2], [3, 3]], result.lines.first["members"]
  end

  # A GROUP INSIDE A NESTED SEQUENCE. `member:= step | sequence`, and a sequence holds steps —
  # g.parallel included — so `[g.parallel([l, ty]), qs]` is the two-source fan-in's natural
  # spelling. The bench caught deepseek writing exactly this and the builder answering "Got object":
  # a sequence member could hold steps but not a group.
  test "a group inside a nested sequence is a step of it, at any depth" do
    result = build(<<~JS, tool_names: %w[bash])
      const t = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const ts = g.model({ prompt: "Summarise the test failures." });
      const l = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const ty = g.tool({ name: "bash", input: { command: "bin/srb tc" } });
      const quality = g.parallel([l, ty]);
      const qs = g.model({ prompt: "Summarise code quality from lint and types." });
      g.parallel([[t, ts], [quality, qs]]);
      g.model({ prompt: "Write the report from the two summaries." });
    JS

    assert_predicate result, :built?, result.inspect
    outer = result.steps.first["parallel"]
    assert_equal [%w[tool-1 model-1], ["parallel", "model-2"]],
      outer.map { |member| member.map { |step| step.keys.first == "parallel" ? "parallel" : step.values.first["key"] } }
    assert_equal %w[tool-2 tool-3], outer[1][0]["parallel"].map { |step| step["tool"]["key"] }
    assert_equal [{ "line" => 7, "members" => [[1, 2], [{ "line" => 5, "members" => [3, 4] }, 6]] }, 8], result.lines,
      "the line tree mirrors the step tree: the inner group carries its own line and members"

    deeper = build(<<~JS, tool_names: %w[bash])
      const a = g.tool({ name: "bash" });
      const b = g.tool({ name: "bash" });
      const inner = g.parallel([a, b]);
      const c = g.tool({ name: "bash" });
      const middle = g.parallel([[inner, c]]);
      const d = g.model({ prompt: "d" });
      g.parallel([[middle, d], g.tool({ name: "bash" })]);
      g.model({ prompt: "end" });
    JS
    assert_predicate deeper, :built?, deeper.inspect
    assert_equal "parallel", deeper.steps.first["parallel"][0][0].keys.first
    assert_equal "parallel", deeper.steps.first["parallel"][0][0]["parallel"][0][0].keys.first
  end

  test "a group in a sequence obeys the regroup rules by its own name" do
    early = refusal(<<~JS)
      const inner = g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })]);
      const m = g.model({ prompt: "m" });
      g.tool({ name: "read_file" });
      g.parallel([[inner, m]]);
    JS
    assert_includes early, "the g.parallel([...]) of 2 members was already placed earlier in the script and followed by another step"

    twice = refusal(<<~JS)
      const inner = g.parallel([g.tool({ name: "read_file" })]);
      const m = g.model({ prompt: "m" });
      g.parallel([[inner, m], [inner]]);
    JS
    assert_includes twice, "the g.parallel([...]) of 1 members is listed twice"
  end

  test "the regroup rules: members are the trailing steps, listed once, and not another group" do
    early = refusal(<<~JS)
      const a = g.tool({ name: "read_file" });
      const b = g.tool({ name: "read_file" });
      g.parallel([a]);
    JS
    assert_includes early, %(g.parallel: every member must be a step built for this group)
    assert_includes early, %("tool-1" was already placed earlier in the script and followed by another step)

    twice = refusal(<<~JS)
      const a = g.tool({ name: "read_file" });
      g.parallel([a, a]);
    JS
    assert_includes twice, %("tool-1" is listed twice)

    assert_includes refusal('g.parallel(["patch.diff"]);'), %(Got "patch.diff")
    assert_includes refusal("g.parallel([]);"), "g.parallel: needs at least one step."
    assert_includes refusal(<<~JS), "g.parallel takes one array: g.parallel([a, b]), not g.parallel(a, b)."
      const a = g.tool({ name: "read_file" });
      const b = g.tool({ name: "read_file" });
      g.parallel(a, b);
    JS
    assert_includes refusal(<<~JS), "a g.parallel([...]) cannot be a member of another"
      const inner = g.parallel([g.tool({ name: "read_file" })]);
      g.parallel([inner, g.tool({ name: "read_file" })]);
    JS
    assert_includes refusal("g.parallel([() => {}]);"), "a member function must build at least one step"
  end

  # THE REGROUP REFUSAL NAMES ITS CAUSE. At the tail, a step the group does not list sits between its
  # members — most often a helper that places a chain and returns only its last step — so the repair is
  # the chain as one member. At the claim, the handle is not in this part of the script at all: an
  # earlier group took it (a member function's steps are that group's members), or this group is
  # inside a member function and the handle was built outside it.
  test "the regroup refusal names the step in the way, or why the handle is not this group's" do
    chain = refusal(<<~JS, tool_names: %w[bash])
      const probe = host => { g.tool({ name: "bash", input: { command: "probe " + host } }); return g.script({ script: "return 1" }); };
      g.parallel(["a", "b", "c"].map(probe));
      g.model({ prompt: "Say which host answered." });
    JS
    assert_equal %(g.parallel: every member must be a step built for this group, e.g. g.parallel([g.tool({...}), g.model({...})]). ) +
      %("script-1" was already placed earlier in the script and followed by another step, "tool-2", that this group does not list. ) +
      %(List a chain of steps as one member, g.parallel([[a, b], other]), or write "tool-2" after the group.), chain

    earlier = %(is already a member of an earlier g.parallel([...]); a step joins one group, and the steps a member ) +
      %(function builds are that group's members. Build a new step for this group.)
    reused = refusal(<<~JS)
      const a = g.tool({ name: "read_file" });
      const b = g.tool({ name: "read_file" });
      g.parallel([a, b]);
      g.parallel([a, g.tool({ name: "read_file" })]);
    JS
    assert_equal %(g.parallel: every member must be a step built for this group, e.g. g.parallel([g.tool({...}), g.model({...})]). "tool-1" #{earlier}),
      reused
    inner = refusal(<<~JS)
      let inner;
      g.parallel([() => { inner = g.tool({ name: "read_file" }); }, g.tool({ name: "read_file" })]);
      g.parallel([inner, g.tool({ name: "read_file" })]);
    JS
    assert_includes inner, %("tool-2" #{earlier})
    outside = refusal(<<~JS)
      const a = g.tool({ name: "read_file" });
      g.parallel([() => { g.parallel([a, g.tool({ name: "read_file" })]); }]);
    JS
    assert_includes outside, %("tool-1" was built outside the member function this group is in; a group inside a member ) +
      %(function takes only the steps that function built. Build the step inside the function, or group it outside.)
  end

  # THE KERNEL PLACES A GROUP'S MEMBERS IN THE ORDER THE LIST GIVES THEM, and a step reads or waits on
  # only a step already placed: a member naming one listed after it is refused at the door
  # (`unknown_task_reference`), so the builder refuses it first, with the repair.
  test "a group member that reads or waits on a member listed after it is refused with the repair" do
    assert_equal %(g.parallel: "model-1" reads "tool-1", listed after it; list a step after the steps it reads.), refusal(<<~JS)
      const source = g.tool({ name: "read_file", input: { path: "a" } });
      const reader = g.model({ prompt: "Summarise it.", results: [source] });
      g.parallel([reader, source]);
    JS
    assert_equal %(g.parallel: "tool-2" waits for "tool-1", listed after it; list a step after the steps it waits for.), refusal(<<~JS)
      const first = g.tool({ name: "read_file" });
      const second = g.tool({ name: "read_file", after: [first] });
      g.parallel([second, first]);
    JS
    assert_includes refusal(<<~JS), %("model-1" reads "tool-1", listed after it)
      const a = g.tool({ name: "read_file" });
      g.parallel([() => { g.model({ prompt: "p", results: [a] }); }, a]);
    JS
    assert_includes refusal(<<~JS), %("model-1" reads "tool-1", listed after it), "a nested group is walked in place"
      const x = g.tool({ name: "read_file" });
      const inner = g.parallel([() => { g.model({ prompt: "p", results: [x] }); }]);
      g.parallel([[inner, x]]);
    JS

    built = build(<<~JS)
      const a = g.tool({ name: "read_file" });
      const b = g.tool({ name: "read_file" });
      const c = g.model({ prompt: "check", after: [a], results: [b] });
      g.parallel([a, [b, c]]);
      g.model({ prompt: "report", results: [c, a] });
    JS
    assert_predicate built, :built?, "a member naming one listed before it, or a step outside the group, is placed as written"
  end

  # A STEP'S OWN OPTION WRITTEN INSIDE INPUT: `after:` goes beside `input`, and a tool reads nothing, so
  # the handle-throw sentence ("pass it in results: to a later g.model or g.script step") names a repair
  # that does not apply. The key alone is no mistake — a tool may take an `after` argument of its own —
  # so only a step handle beneath it gets these sentences.
  test "a handle under after or results inside a tool's input, or a tool's results, names where the option goes" do
    reads = "a tool reads nothing. To wait for a step, write after: [step] beside input; to use a step's result, " \
      "give it to a g.model or g.script with results: [step]."
    assert_equal %(g.tool: after: goes beside input, not inside it: g.tool({ name: "bash", input: { ... }, after: [step] }).),
      refusal(<<~JS)
        const migrate = g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } });
        g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump", after: [migrate] } });
      JS
    assert_equal "g.tool: results: does not go inside input; #{reads}",
      refusal('const m = g.tool({ name: "bash" }); g.tool({ name: "bash", input: { command: "x", results: [m] } });')
    assert_equal "g.tool: results: is not an option; #{reads}",
      refusal('const m = g.tool({ name: "bash" }); g.tool({ name: "bash", input: { command: "x" }, results: [m] });')
    assert_includes refusal('const m = g.tool({ name: "bash" }); g.tool({ name: "bash", input: { options: { after: [m] } } });'),
      "g.tool: after: goes beside input, not inside it"
    assert_includes refusal('const m = g.parallel([g.tool({ name: "bash" })]); g.tool({ name: "bash", input: { after: m } });'),
      "g.tool: after: goes beside input, not inside it"

    own = build('g.tool({ name: "bash", input: { command: "at", after: "10:00", results: ["tool-1"] } });')
    assert_predicate own, :built?, "a tool's own after or results argument is its input"
    assert_equal({ "command" => "at", "after" => "10:00", "results" => ["tool-1"] }, own.steps.sole.dig("tool", "input"))
  end

  test "until is all, any, or a number no larger than the group, and a boolean falls into the same sentence" do
    detail = refusal(<<~JS)
      g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })], { until: "first" });
    JS
    assert_equal %(until: expected "all", "any", or a number no larger than the group (2), got "first".), detail
    assert_includes refusal('g.parallel([g.tool({ name: "read_file" })], { until: 2 });'), "got 2."
    assert_includes refusal('g.parallel([g.tool({ name: "read_file" })], { until: true });'),
      %(until: expected "all", "any", or a number no larger than the group (1), got true.)
    assert_includes refusal('g.parallel([g.tool({ name: "read_file" })], { until: false });'), "got false."
    assert_includes refusal('g.parallel([g.tool({ name: "read_file" })], { losers: "cancel" });'),
      "losers: is not an option: a race from a script cancels its losers; there is no loser option."
    assert_includes refusal('g.parallel([g.tool({ name: "read_file" })], { key: "k" });'),
      %(g.parallel: unknown option "key". The one option is until.)
  end

  # THE FAN'S OLD WORD: `wait` on a g.parallel was the fan's join word and collided with the call's
  # boolean `wait` — the models wrote `{wait: 1}` / `{wait: "any"}` on the fan to say "nothing waits
  # on this". On a fan it is refused by name with the fan's word and the call's home; on a step it
  # is the call's sentence, like every per-step "later".
  test "wait on a fan names the fan's word and the call's home; wait on a step is the call's sentence" do
    assert_equal %(wait: is not an option on g.parallel; the fan's word is until: — "all" (the default), "any", ) \
      "or a number of successes — and wait: true belongs on the compose call, outside the script.",
      refusal('g.parallel([g.tool({ name: "read_file" })], { wait: "any" });')
    call = "wait: is not an option. The whole compose call runs in the background unless you call it with " \
      "wait: true; steps run in the order you write them, and work nothing should wait on goes in its " \
      "own call or beside the rest in one g.parallel([...])."
    assert_equal call, refusal('g.tool({ name: "read_file", wait: true });')
    assert_equal call, refusal('g.model({ prompt: "p", wait: false });')
  end

  # THE REFUSAL TABLE. Every word the old grammar spelled answers with its
  # replacement, and every option outside the closed set is refused at the
  # line — never dropped, which is how `g.ask({prompt})` once vanished.
  test "every deleted word is refused with the sentence that names the repair" do
    edge = "is not an option. A step reads only what you hand it: results: [a, b] on a g.model or g.script " \
      "hands it those results; after: [a] on any leaf waits without a result; no input_from or join."
    # The WHEN word is on the CALL: every per-step spelling of "later" is answered with the call's
    # `wait` and the fan.
    call = "is not an option. The whole compose call runs in the background unless you call it with " \
      "wait: true; steps run in the order you write them, and work nothing should wait on goes in its " \
      "own call or beside the rest in one g.parallel([...])."
    {
      'g.model({ prompt: "p", input_from: ["patch.diff"] });' => "input_from: #{edge}",
      'g.tool({ name: "read_file", depends_on: [] });' => "depends_on: #{edge}",
      'g.model({ prompt: "p", reading: "x" });' => "reading: #{edge}",
      'g.parallel([g.tool({ name: "read_file" })], { mode: "any" });' =>
        'mode: is not an option; the barrier word is until: on g.parallel — "all" (the default), "any", or a number.',
      'g.parallel([g.tool({ name: "read_file" })], { quorum_k: 2 });' => "quorum_k: is not an option",
      'g.parallel([g.tool({ name: "read_file" })], { loser_policy: "cancel_losers" });' =>
        "loser_policy: is not an option: a race from a script cancels its losers; there is no loser option.",
      'g.model({ prompt: "p", run_in_background: true });' => "run_in_background: #{call}",
      'g.tool({ name: "read_file", detached: true });' => "detached: #{call}",
      'g.model({ prompt: "p", detach: true });' => "detach: #{call}",
      'g.model({ prompt: "p", background: true });' => "background: #{call}",
      'g.model({ prompt: "p", detachable: false });' => "detachable: #{call}",
      'g.ask({ prompt: "p", outlives_turn: true });' => "outlives_turn: #{call}",
      'g.tool({ name: "read_file", serial: true });' =>
        "serial: is not an option: steps run in the order you write them, one after another.",
      'g.ask({ question: "which?" });' => "question: is not an option; the field is prompt.",
      'g.tool({ name: "read_file", on_failure: "propagate" });' =>
        "on_failure is not a compose option: a step that fails reaches you as an error envelope.",
      'g.tool({ name: "read_file", retry: 2 });' => "retry is not a compose option; the step inherits it from this round.",
      'g.model({ prompt: "p", visibility: "hidden" });' => "visibility is not a compose option",
      'g.model({ prompt: "p", configuration: {} });' => "configuration is not a compose option",
      'g.model({ prompt: "p", compaction: {} });' => "compaction is not a compose option",
      'g.model({ prompt: "p", fan_on_failure: "absorb" });' => "fan_on_failure is not a compose option",
      'g.tool({ name: "bash", command: "bin/rails test" });' =>
        %(g.tool: unknown option "command". Tool arguments go under input: g.tool({ name: "bash", input: { command: … } })),
      'g.model({ prompt: "p", temperature: 0 });' =>
        %(g.model: unknown option "temperature". The options are prompt, model, tools, instructions, key, after, results.),
      'g.ask({ prompt: "p", who: "me" });' =>
        %(g.ask: unknown option "who". The options are prompt, options, multi, key, timeout_ms, after.),
    }.each do |script, sentence|
      assert_includes refusal(script), sentence, script
    end
  end

# THE MODEL REFERENCE. `model:` is a "provider/ref" string or the door's
# object `{model: "provider/ref", reasoning_effort?}` (agent_loops.md
# "model"); any other shape the kernel refuses as `invalid_model` after the
# evaluator said yes — a capture the bench scored valid was refused at
# the door. The evaluator refuses it first, with the sentence it already had.
test "a model option that is not a provider/ref is refused before the door" do
  sentence = %(g.model: model is a name like "provider/model", or omit it to run as the model you are)
  [
    'g.model({ prompt: "p", model: { s_security: "{security}" } });',
    'g.model({ prompt: "p", model: { reasoning_effort: "high" } });',
    'g.model({ prompt: "p", model: "mock" });',
    'g.model({ prompt: "p", model: { model: "dev/mock", reasoning_effort: 3 } });',
  ].each { |script| assert_includes refusal(script), sentence, script }

  built = build('g.model({ prompt: "p", model: { model: "dev/mock", reasoning_effort: "high" } }); ' \
    'g.model({ prompt: "q", model: "dev/mock" }); g.model({ prompt: "r" });')
  assert_predicate built, :built?
  assert_equal [{ "model" => "dev/mock", "reasoning_effort" => "high" }, { "model" => "dev/mock" }, nil],
    built.steps.map { |step| step["model"]["model"] }
end

  test "an unknown verb teaches the supported verbs, and g.join names the barrier's real home" do
    %w[race append append_parallels all then window].each do |verb|
      assert_equal "g.#{verb} is not a compose verb. Build steps with g.tool / g.model / g.ask / g.wait / g.script; " \
        "run steps at once with g.parallel([step, ...]).", refusal("g.#{verb}([]);"), verb
    end
    assert_equal "g.join is not a builder: the kernel places barriers. Put the steps in g.parallel([...]) — " \
      'until: "all" is the default, "any" races them, a number is a quorum — and list what the next step needs ' \
      "in its results: [a, b].",
      refusal('const a = g.tool({ name: "read_file" }); g.join([a], { mode: "any" });')
  end

  # A handle is a label. Every road from it to a string is the one sentence,
  # including through the array a group returns.
  test "a handle throws from toString, valueOf, toPrimitive, toJSON, and through a group's join" do
    sentence = "The result of tool-1 is not known while the script runs. A call returns only a label for " \
      "its step; never put it in a prompt or an input — pass it in results: to a later g.model or g.script step."
    {
      'const h = g.tool({ name: "read_file" }); g.model({ prompt: "Edit the file that matched: " + h });' => sentence,
      'const h = g.tool({ name: "read_file" }); g.model({ prompt: `${h}` });' => sentence,
      'const h = g.tool({ name: "read_file" }); g.model({ prompt: "n" + (h * 2) });' => sentence,
      'const h = g.tool({ name: "read_file" }); g.tool({ name: "bash", input: { command: h } });' => sentence,
      'const h = g.tool({ name: "read_file" }); g.tool({ name: "bash", input: { c: JSON.stringify(h) } });' => sentence,
      'const reviews = g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })]); ' \
        'g.model({ prompt: "Synthesize: " + reviews.join(", ") });' => sentence,
    }.each do |script, expected|
      assert_includes refusal(script), expected, script
    end

    unused = build('const h = g.tool({ name: "read_file" }); g.model({ prompt: "p" });')
    assert_predicate unused, :built?, "binding a handle and never using it is a valid script"
  end

  # A handle is a Proxy: the property a RESULT would have — a method
  # (`r1.includes`, `.match`), a field (`.output`), an assignment, an `in`
  # probe, a spread or Object.keys (which would carry the label's two
  # fields into an input silently), a destructuring, a `model:` — is the
  # same sentence, exactly, never V8's raw "is not a function" (the
  # bench's `other` bucket, which taught nothing). The label's own `key`
  # and `kind` read, a group still claims it, a promise check asks `then`
  # and gets undefined, symbols answer undefined, and JSON.stringify is
  # refused with the sentence rather than rendering the label.
  test "a property a result would have throws the sentence; the label's own key and kind read" do
    sentence = "The result of tool-1 is not known while the script runs. A call returns only a label for " \
      "its step; never put it in a prompt or an input — pass it in results: to a later g.model or g.script step."
    {
      'const r = g.tool({ name: "bash", input: { command: "grep -r TODO" } }); ' \
        'if (r.includes("TODO")) g.model({ prompt: "fix" });' => sentence,
      'const r = g.tool({ name: "read_file" }); const m = r.match(/x/); g.model({ prompt: "p" });' => sentence,
      'const r = g.tool({ name: "read_file" }); g.model({ prompt: "p", instructions: r.output });' => sentence,
      'const r = g.tool({ name: "read_file" }); r.output = "x"; g.model({ prompt: "p" });' => sentence,
      'const r = g.tool({ name: "read_file" }); JSON.stringify(r); g.model({ prompt: "p" });' => sentence,
      'const r = g.tool({ name: "read_file" }); g.tool({ name: "bash", input: { a: r.result } });' => sentence,
      'const r = g.tool({ name: "read_file" }); if ("output" in r) g.model({ prompt: "p" });' => sentence,
      'const r = g.tool({ name: "read_file" }); g.tool({ name: "bash", input: { ...r } });' => sentence,
      'const r = g.tool({ name: "read_file" }); g.model({ prompt: "see " + Object.keys(r) });' => sentence,
      'const r = g.tool({ name: "read_file" }); const [first] = r; g.model({ prompt: "p" });' => sentence,
      'const r = g.tool({ name: "read_file" }); g.model({ prompt: "p", model: r });' => sentence,
    }.each do |script, expected|
      assert_equal expected, refusal(script), script
    end

    built = build(<<~JS)
      const a = g.tool({ name: "read_file", key: "a" });
      const b = g.model({ prompt: "p" });
      if (a.key !== "a" || a.kind !== "tool" || b.key !== "model-1" || b.kind !== "model") throw new Error("label");
      if (!("key" in a) || "then" in a) throw new Error("in");
      if (a.then !== undefined || a[Symbol.toStringTag] !== undefined) throw new Error("symbol");
      if (typeof Promise.resolve(a) !== "object") throw new Error("promise");
      g.parallel([a, b]);
      g.model({ prompt: "after" });
    JS
    assert_predicate built, :built?, built.inspect
    assert_equal %w[parallel model], built.steps.map { |step| step.keys.first }
    assert_equal %w[a model-1], built.steps[0]["parallel"].map { |member| member.values.first["key"] }
  end

  test "g.tool needs a name, and the example is the round's own first tool" do
    assert_equal %(g.tool needs a name, e.g. { name: "read" }), refusal("g.tool({ input: {} });", tool_names: %w[read grep])
    assert_equal %(g.tool needs a name, e.g. { name: "<one of your tools>" }), refusal("g.tool({});", tool_names: [])
    assert_equal %(g.model needs a prompt, e.g. { prompt: "..." }), refusal("g.model({});")
    assert_equal %(g.ask needs a prompt, e.g. { prompt: "..." }), refusal("g.ask({ timeout_ms: 5 });")
    assert_includes refusal('g.tool({ name: "read_file", input: "a" });'), "input must be an object"
    assert_includes refusal('g.model({ prompt: "p", tools: [{}] });'), "tools names the tools this step keeps"
  end

  # No step carries a background field: the WHEN word is `wait` on the
  # compose CALL, and a step is placed as the kernel's `detached: false`.
  test "key and timeout_ms ride the step; an omitted model is omitted; no step carries a background field" do
    result = build(<<~JS)
      g.tool({ name: "bash", input: { command: "sleep" }, key: "slow", timeout_ms: 5 });
      g.model({ prompt: "think", model: "dev/mock-text", tools: ["read_file"], instructions: "terse" });
      g.ask({ prompt: "which database?", timeout_ms: 60000 });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal({ "key" => "slow", "name" => "bash", "input" => { "command" => "sleep" }, "timeout_ms" => 5 },
      result.steps[0]["tool"])
    assert_equal({ "key" => "model-1", "prompt" => "think", "model" => { "model" => "dev/mock-text" },
                   "tools" => ["read_file"], "instructions" => "terse" }, result.steps[1]["model"])
    assert_equal({ "key" => "ask-1", "prompt" => "which database?", "timeout_ms" => 60000 }, result.steps[2]["ask"])
  end

  # A second argument to a step verb was READ BY NOTHING: the bench caught
  # deepseek writing `g.tool({...}, { run_in_background: true })` and the
  # builder placing a foreground step without a word. Refused, like the
  # second argument to `g.parallel`.
  test "a step verb takes one object; a second is refused, never dropped" do
    %w[tool model ask].each do |verb|
      fields = verb == "tool" ? 'name: "bash"' : 'prompt: "p"'
      detail = refusal("g.#{verb}({ #{fields} }, { key: \"k\" });")
      assert_equal "g.#{verb} takes one object: g.#{verb}({ ..., key: \"…\" }), " \
                   "not g.#{verb}({ ... }, { ... }).", detail
    end
  end

  # Every host-dependent global, not just the two obvious calls: `new
  # Date()`, `Date#toString` and `Intl` carry the wall clock and the
  # timezone, the weak-ref pair the collector's timing. Any of them folded
  # into a step breaks the replay that recovers a job run twice.
  test "the clock, the dice and the host's locale are removed, not discouraged" do
    {
      "Date.now()" => "Date",
      "new Date()" => "Date",
      "String(new Date())" => "Date",
      "Intl.DateTimeFormat().resolvedOptions().timeZone" => "Intl",
      "new WeakRef({})" => "WeakRef",
      "new FinalizationRegistry(() => {})" => "FinalizationRegistry",
      "Math.random()" => "Math.random()",
    }.each do |forbidden, named|
      result = build("g.tool({ name: \"read_file\", input: { v: #{forbidden} } });")
      assert_equal :script_error, result.refusal, forbidden
      assert_includes result.detail, "#{named} is unavailable", forbidden
      assert_includes result.detail,
        "a compose script must build the same graph every time it runs", forbidden
      assert_includes result.detail, "through params", forbidden
    end
  end

  # The recovery in `Compose::Run` — the job ran twice, the second run
  # rebuilds the same keys and finds them — is only as good as this.
  test "the same script on two isolates is byte-identical" do
    script = <<~JS
      const hosts = params.hosts.map(host =>
        g.tool({ name: "read_file", input: { host, label: JSON.stringify({ host }) } })
      );
      g.parallel(hosts);
      const seen = Object.keys({ z: 1, a: 2 }).join(",");
      g.model({ prompt: "summarize " + seen + " for " + params.title });
    JS
    params = { "hosts" => %w[alpha bravo charlie], "title" => "sweep" }

    first = build(script, params)
    second = build(script, params)

    assert_predicate first, :built?
    assert_equal({ steps: first.steps, lines: first.lines },
      { steps: second.steps, lines: second.lines })
  end

  # And across HOSTS: a subprocess under another timezone and locale places
  # the same bytes, because nothing host-dependent is reachable.
  test "the same script under another timezone and locale is byte-identical" do
    script = 'g.tool({ name: "read_file", input: { n: (1234.5).toFixed(1), s: "b".localeCompare("a") } }); ' \
      'g.model({ prompt: "x" });'
    here = build(script)
    program = <<~RUBY
      require "mini_racer"
      require "json"
      require #{Rails.root.join("lib/nexus/compose/evaluator.rb").to_s.inspect}
      result = Nexus::Compose::Evaluator.call(script: #{script.inspect}, tool_names: ["read_file"])
      print JSON.generate({ "steps" => result.steps, "lines" => result.lines })
    RUBY
    there = IO.popen({ "TZ" => "Pacific/Kiritimati", "LANG" => "tr_TR.UTF-8", "LC_ALL" => "tr_TR.UTF-8" },
      [RbConfig.ruby, "-e", program], err: %i[child out], &:read)

    assert_equal 0, $CHILD_STATUS.exitstatus, there
    assert_equal({ "steps" => here.steps, "lines" => here.lines }, JSON.parse(there))
  end

  test "a runaway script fails its own task and nothing else" do
    result = build("while (true) {}")
    assert_equal :script_timed_out, result.refusal
  end

  test "a throw, a syntax error and an empty script are each typed" do
    assert_equal :script_error, build("throw new Error('nope');").refusal
    assert_equal :script_syntax_error, build("g.tool({").refusal
    assert_equal :script_required, build("   ").refusal
    assert_equal :script_too_large,
      build("//" + ("x" * Evaluator::MAX_SOURCE_BYTES)).refusal
  end

  test "the isolate grants nothing — no host, no io, no require" do
    %w[
      typeof\ process
      typeof\ require
      typeof\ fetch
      typeof\ console
      typeof\ XMLHttpRequest
    ].each do |probe|
      result = build("g.tool({ name: \"read_file\", input: { seen: #{probe} } });")
      assert_predicate result, :built?
      assert_equal "undefined", result.steps.sole.dig("tool", "input", "seen"),
        "#{probe} must not exist: the script's only reachable effect is " \
          "its return value"
    end
  end

  test "each step remembers the SCRIPT line that placed it, helpers included" do
    result = build(<<~JS)
      function reader(path) {
        return g.tool({ name: "read_file", input: { path } });
      }
      const a = reader("one.rb");
      const b = reader("two.rb");
      g.model({ prompt: "go" });
    JS

    assert_equal 3, result.lines.length
    assert_equal [2, 2, 6], result.lines,
      "a kernel refusal arrives positional (steps[1].prompt); the " \
        "model needs the line of ITS OWN script that produced it"
    assert_equal result.lines[0], result.lines[1],
      "two calls through one helper attribute to the helper's own line"
    assert_operator result.lines[2], :>, result.lines[1],
      "and a direct call attributes to itself, later in the file"
  end

  test "duplicate keys are caught in the builder, before the door sees them" do
    result = build(<<~JS)
      g.tool({ name: "read_file", key: "same" });
      g.tool({ name: "bash", key: "same" });
    JS
    assert_equal :script_error, result.refusal
    assert_includes result.detail, "duplicate task key"
  end

  # A model reading "it receives g and params" writes the function. A
  # bare arrow expression is evaluated and discarded by `new Function` —
  # nothing built, and no error to read. Found by the first live probe,
  # in the very first script a real model wrote for this surface.
  test "a script written as a function is called, at arity one or two" do
    two = build(<<~JS, { "hosts" => %w[alpha bravo] })
      (g, params) => {
        g.parallel(params.hosts.map(host => g.tool({ name: "read_file", input: { host } })));
        g.model({ prompt: "summarize" });
      }
    JS
    assert_predicate two, :built?, two.inspect
    assert_equal %w[parallel model], two.steps.map { |step| step.keys.first }

    one = build(<<~JS)
      function (g) {
        g.tool({ name: "read_file" });
        g.model({ prompt: "summarize" });
      }
    JS
    assert_predicate one, :built?, one.inspect
    assert_equal %w[tool model], one.steps.map { |step| step.keys.first }
  end

  # THE EVALUATOR LOADS WITHOUT THE APPLICATION. A probe that drives a
  # real model's script has to run the SHIPPED evaluator and the SHIPPED
  # builder library — a harness lookalike would prove something about
  # the lookalike. One stray ActiveSupport call breaks that silently, in
  # a paid opt-in probe nobody runs on a red build, so it is pinned here
  # in a subprocess with nothing loaded.
  test "the evaluator runs in a bare ruby process" do
    script = 'g.tool({ name: "read_file", input: { path: "a" } }); g.oops();'
    program = <<~RUBY
      require "mini_racer"
      require #{Rails.root.join("lib/nexus/compose/evaluator.rb").to_s.inspect}
      result = Nexus::Compose::Evaluator.call(script: #{script.inspect})
      print result.refusal, "|", result.detail
    RUBY
    out = IO.popen([RbConfig.ruby, "-e", program], err: %i[child out], &:read)

    assert_equal 0, $CHILD_STATUS.exitstatus, out
    assert_match(/\Ascript_error\|/, out)
    assert_match(/g\.oops is not a compose verb/, out)
  end

  test "an ask carries its question" do
    result = build('g.ask({ prompt: "which database?", timeout_ms: 60000 });')

    assert_predicate result, :built?
    assert_equal "which database?", result.steps.sole.dig("ask", "prompt")
  end

  # A WHOLE SCRIPT IN QUOTES places nothing: one string or template literal is an expression whose
  # statements are only text. A model that wrapped its script — or encoded it twice, `\n` escapes and
  # all — read the bare no-step sentence and concluded template literals were unsupported, so the
  # sentence names the quotes, keeping the no-step words for every reader of them.
  test "a script that is one quoted string is told so; any other empty script keeps the no-step sentence" do
    [
      %("const t = g.tool({ name: 'bash', input: { command: 'echo probe' } });\\ng.parallel([t]);"),
      %(  'g.tool({ name: "read_file" });'  ),
      "`\nconst a = g.tool({ name: \"read_file\" });\n`;",
    ].each do |script|
      result = build(script)
      assert_equal :script_error, result.refusal, script
      assert_includes result.detail, "one quoted string", script
      assert_includes result.detail, "not inside quotes", script
      assert_includes result.detail, Evaluator::NO_STEP, "the no-step words stay inside it"
    end

    ['"use strict"; if (params.go) g.tool({ name: "read_file" });',
     'if (params.go) g.tool({ name: "read_file" }); "done"'].each do |script|
      result = build(script)
      assert_equal [:script_error, Evaluator::NO_STEP], [result.refusal, result.detail], script
    end
  end
end
