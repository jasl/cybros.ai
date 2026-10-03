require_relative "compose_bench_harness"

# THE KERNEL'S REFUSALS OF WHAT A SCRIPT BUILT, READ BY THE SCORER: after the evaluator builds the
# steps, `Compose::Lower` refuses some and `Tasks::Compile` refuses others, and the kernel places
# nothing for a script either refuses. The scorer reads both in the kernel's order — every refusal
# of Lower's first, over the whole tree; then Compile's two bounds on the whole batch; then
# Compile's checks step by step, in placement order and each step's key before its fields, in the
# compiler's order — through the kernel's own key format, predicate and bounds, so a static reading
# never lowers a graph the kernel refuses, nor refuses one under another code.
class ComposeBenchRefusalsHarnessTest < Minitest::Test
  include ComposeBenchHarness

  Scoring = E2E::ComposeBench::Scoring
  # A real U+0000 the script builds without writing one in its source: the escape text for it is
  # itself refused where a stage's source carries it, so no case that wants the codepoint spells it.
  NUL = "String.fromCharCode(0)".freeze
  # The escape text for U+0000 — a backslash, then "u0000" — built the same way, with no
  # backslash in the Ruby or the JavaScript source.
  ESCAPE_TEXT = %("see " + String.fromCharCode(92) + "u0000 here").freeze

  # THE SCORER READS THE LOWERING'S REFUSALS OVER THE ROUND'S WHOLE SET: a `g.tool` may name any tool
  # the round declared, a graph verb included, while a `g.model`'s `tools` narrows what a branch
  # inherits, which never holds `compose` or `task`; a key over the kernel's bound is refused. Within
  # a step the kernel's order holds: a `g.tool`'s name before its key, a `g.model`'s key before its
  # tools. Each refusal is the kernel's sentence, bucketed as the loud columns read it.
  def test_the_scorer_reads_the_lowerings_refusals_over_the_rounds_set
    round = [*Tools::NAMES, "compose", "task"]
    have = "You have: #{round.join(", ")}"
    long = "abcdefghijabcdefghijabcdefghijabc"
    refused = lambda do |script|
      scored = E2E::ComposeBench::Scoring.score(Objectives.find("O2"), script: script, params: {}, tool_names: round)
      refute scored["valid_first"], script
      scored.values_at("refusal", "detail", "loud")
    end

    assert_equal ["unknown_tool_name", %(g.model: "read" is not one of your tools. #{have}), "tool_name"],
      refused.(%(g.model({ prompt: "x", tools: ["read"] });))
    assert_equal ["unknown_tool_name", %(g.model: "task" is not one of your tools. #{have}), "tool_name"],
      refused.(%(g.model({ prompt: "x", tools: ["grep", "task"] });))
    assert_equal ["composed_key_too_long", "#{long[0, 32]}… (max 32 characters)", "other"],
      refused.(%(g.tool({ name: "grep", input: { pattern: "x", path: "a" } }); g.model({ key: "#{long}", prompt: "x" });))
    assert_equal "unknown_tool_name", refused.(%(g.tool({ key: "#{long}", name: "curl", input: {} });)).first
    assert_equal "composed_key_too_long", refused.(%(g.model({ key: "#{long}", prompt: "x", tools: ["read"] });)).first

    graph_verb = E2E::ComposeBench::Scoring.score(Objectives.find("O2"),
      script: %(g.tool({ name: "task", input: { prompt: "find it" } });), params: {}, tool_names: round)
    assert graph_verb["valid_first"], "the top level declares the round's own set: #{graph_verb.inspect}"
  end

  # EVERY FIELD THE COMPILER CHECKS OF A STEP A SCRIPT CAN BUILD: the row store's own predicate on
  # a tool's input, an ask's options and a stage's source and params; the codepoint itself in a
  # prompt or instructions; and the byte bounds on a tool's input and a stage's source. Each is the
  # compiler's code, bucketed under it, in the sentence the compose call settles with.
  def test_the_scorer_reads_what_the_kernels_compile_refuses_of_each_step
    {
      %(g.tool({ name: "grep", input: { pattern: "a" + #{NUL}, path: "a" } });) => "invalid_tool_input",
      %(g.tool({ name: "grep", input: { pattern: "x".repeat(#{tool_input_bound}), path: "a" } });) => "tool_input_too_large",
      %(g.ask({ prompt: "Pick" + #{NUL} });) => "invalid_prompt",
      %(g.ask({ prompt: "Pick one.", options: ["a", "b" + #{NUL}] });) => "invalid_ask_options",
      %(g.model({ prompt: "Report" + #{NUL} });) => "invalid_prompt",
      %(g.model({ prompt: "Report.", instructions: "Be brief" + #{NUL} });) => "invalid_instructions",
      %(g.model({ prompt: "Report.", instructions: "" });) => "invalid_instructions",
      %(g.script({ script: "   " });) => "script_required",
      %(g.script({ script: "return 1;" + " ".repeat(#{source_bound}) });) => "script_too_large",
      %(g.script({ script: "return 1;" + #{NUL} });) => "invalid_script",
      %(g.script({ script: "return params.a;", params: { a: "x" + #{NUL} } });) => "invalid_script_params",
      %(g.tool({ key: "read.config", name: "grep", input: { pattern: "x", path: "a" } });) => "invalid_task_key",
      %(g.wait({ task: "bad.task" });) => "invalid_task_key",
    }.each do |script, code|
      assert_equal [code, code], refused(script).values_at("refusal", "loud"), script
    end

    detail = refused(%(g.tool({ name: "grep", input: { pattern: "x", path: "a" } }); g.model({ prompt: "Report" + #{NUL} });))["detail"]
    assert_equal "The composed graph was refused:\n#{JSON.pretty_generate([{ "code" => "invalid_prompt", "step" => "model-1" }])}",
      detail, "the compose call's own sentence, naming the step the script wrote"
  end

  # AT THE KERNEL'S BOUNDS A STEP IS THE KERNEL'S TO PLACE: the bytes are measured where the row
  # measures them, a tool's input as canonical JSON, a stage's source as its UTF-8 bytes.
  def test_a_step_at_the_kernels_byte_bounds_places
    at = tool_input_bound - Nexus::CanonicalJson.bytesize({ "pattern" => "", "path" => "a" })
    assert_nil lowering_refusal(%(g.tool({ name: "grep", input: { pattern: "x".repeat(#{at}), path: "a" } });))
    assert_equal "tool_input_too_large",
      lowering_refusal(%(g.tool({ name: "grep", input: { pattern: "x".repeat(#{at + 1}), path: "a" } });)).refusal
    assert_nil lowering_refusal(%(g.script({ script: "return 1;" + " ".repeat(#{source_bound - 9}) });))
    assert_equal "script_too_large", lowering_refusal(%(g.script({ script: "return 1;" + " ".repeat(#{source_bound - 8}) });)).refusal
  end

  # THE BATCH BOUNDS ARE THE KERNEL'S: its leaf bound on a model-authored append — every leaf a
  # group holds counts — and the whole tree's bytes, before any step's own check.
  def test_the_batch_bounds_are_the_kernels
    most = Nexus::StepBounds::KERNEL_MAX_TASKS_PER_REQUEST
    assert_nil lowering_refusal(greps(most)), "a batch at the kernel's leaf bound places"
    assert_equal "too_many_steps", lowering_refusal(greps(most + 1)).refusal
    assert_equal "too_many_steps", lowering_refusal(greps(most - 1) + %(g.parallel([#{grep}, #{grep}]);)).refusal,
      "a group's members are leaves"

    assert_equal "steps_payload_too_large", lowering_refusal(oversized).refusal
    assert_equal "The composed graph was refused:\n#{JSON.pretty_generate([{ "code" => "steps_payload_too_large" }])}",
      lowering_refusal(oversized).detail, "a bound on the whole batch names no step"
  end

  # THE KERNEL'S ORDER: every Lower refusal before any of Compile's, wherever it stands; Compile's
  # bounds on the whole batch before any step's own; then the first step that fails in placement
  # order — a group's members in turn, a nested sequence step by step — and within a step its fields
  # in the compiler's order.
  def test_the_refusals_come_in_the_kernels_order
    nul_tool = %(g.tool({ name: "grep", input: { pattern: #{NUL}, path: "a" } });)
    assert_equal "unknown_tool_name",
      lowering_refusal(%(g.model({ prompt: "a" + #{NUL} }); g.tool({ name: "curl", input: {} });)).refusal,
      "a Lower refusal wins over an earlier step's Compile refusal"
    assert_equal "unknown_tool_name", lowering_refusal(greps(Nexus::StepBounds::KERNEL_MAX_TASKS_PER_REQUEST) +
      %(g.tool({ name: "curl", input: {} });)).refusal, "and over a batch bound"
    assert_equal "too_many_steps", lowering_refusal(nul_tool + greps(Nexus::StepBounds::KERNEL_MAX_TASKS_PER_REQUEST)).refusal
    assert_equal "steps_payload_too_large", lowering_refusal(nul_tool + oversized).refusal

    grouped = lowering_refusal(<<~JS)
      g.parallel([
        [g.model({ prompt: "Plan." }), g.ask({ prompt: "Which?", options: ["a" + #{NUL}] })],
        g.tool({ name: "grep", input: { pattern: #{NUL}, path: "a" } }),
      ]);
      g.model({ prompt: "x" + #{NUL} });
    JS
    assert_equal %w[invalid_ask_options ask-1], [grouped.refusal, JSON.parse(grouped.detail.lines.drop(1).join).sole.fetch("step")]

    assert_equal "script_too_large", lowering_refusal(%(g.script({ script: "return 1;" + #{NUL} + " ".repeat(#{source_bound}) });)).refusal
    assert_equal "invalid_script", lowering_refusal(%(g.script({ script: "return 1;" + #{NUL}, params: { a: #{NUL} } });)).refusal
    assert_equal "invalid_tool_input",
      lowering_refusal(%(g.tool({ name: "grep", input: { pattern: #{NUL} + "x".repeat(#{tool_input_bound}), path: "a" } });)).refusal
    assert_equal "invalid_prompt", lowering_refusal(%(g.ask({ prompt: "Pick" + #{NUL}, options: [#{NUL}] });)).refusal
  end

  # A STEP'S OWN KEY IS THE FIRST THING THE COMPILER CHECKS OF IT, against the format every node
  # row's key carries: so a key the format refuses is refused under its own code whatever else the
  # step carries, and an earlier step's field still comes before a later step's key. At the top
  # level the key the compiler reads is `Compose::Lower`'s namespaced one, the call's key leading,
  # so a script key may start with "_" or "-"; a stage's keys are read as the script wrote them.
  # A wait's `task` — an identity it observes, never namespaced — is read after the wait's own key.
  def test_a_steps_own_key_is_read_first_as_the_kernels_compiler_reads_it
    ["read.config", "a/b", "a b", "é"].each do |key|
      assert_equal ["invalid_task_key", key],
        refused_step(%(g.tool({ key: "#{key}", name: "grep", input: { pattern: "x", path: "a" } });)), key
    end
    assert_equal ["invalid_task_key", "read.config"],
      refused_step(%(g.tool({ key: "read.config", name: "grep", input: { pattern: #{NUL}, path: "a" } });)),
      "the key before the input"
    assert_equal ["invalid_task_key", "bad.key"],
      refused_step(%(g.tool({ name: "grep", input: { pattern: "x", path: "a" } }); g.model({ key: "bad.key", prompt: "x" + #{NUL} });)),
      "the key before the prompt"
    assert_equal ["invalid_prompt", "model-1"],
      refused_step(%(g.model({ prompt: "x" + #{NUL} }); g.model({ key: "bad.key", prompt: "y" });)),
      "an earlier step's field before a later step's key"

    ["_x", "-x"].each do |key|
      script = %(g.tool({ key: "#{key}", name: "grep", input: { pattern: "x", path: "a" } });)
      assert_nil lowering_refusal(script), "#{key}: the call's key leads the key the compiler reads"
      assert_equal ["invalid_task_key", key], refused_step(script, stage: true), "#{key}: a stage's key is read as written"
    end
    longest = %(g.tool({ key: "#{"a" * Shape::MAX_SCRIPT_KEY}", name: "grep", input: { pattern: "x", path: "a" } });)
    assert_nil lowering_refusal(longest), "the longest key Lower admits fits the format under the namespace"
    assert_nil lowering_refusal(longest, stage: true)

    assert_equal ["invalid_task_key", "wait-1"], refused_step(%(g.wait({ task: "bad.task" });))
    assert_equal ["invalid_task_key", "bad.key"], refused_step(%(g.wait({ key: "bad.key", task: "bad.task" });)),
      "the wait's own key before the task it names"
    assert_nil lowering_refusal(%(g.wait({ task: "r1t0" });))
  end

  # A STAGE'S KEYS ARE ITS SCRIPT'S OWN: the inliner reads a stage's steps as the kernel's stage
  # lowering does, so a key the top level would place under its namespace fails the stage there.
  def test_a_stage_whose_step_key_the_kernels_compiler_refuses_stays_a_leaf
    built = evaluate(%(g.script({ script: 'g.tool({ key: "_x", name: "grep", input: { pattern: "x", path: "a" } });' });))
    inlined = Shape.inline(built.steps, tool_names: Tools::NAMES)
    assert_empty inlined.inlined
    assert_equal [%w[script-1 invalid_task_key]], inlined.refused.map { |refused| [refused.key, refused.refusal] }
  end

  # THE CODEPOINT, NOT THE PREDICATE, IN A PROMPT OR INSTRUCTIONS: the compiler refuses a model's or
  # an ask's prompt and a model's instructions only for U+0000 itself, so the six characters of its
  # escape written as text place there; the row store's predicate, which refuses that text as well,
  # is what reads a tool's input. Both sides pinned, so neither check stands in for the other.
  def test_the_escape_text_for_nul_is_read_by_the_codepoint_in_a_prompt_and_by_the_predicate_in_an_input
    assert_equal "see \\u0000 here", evaluate(%(g.model({ prompt: #{ESCAPE_TEXT} });)).steps.sole.fetch("model").fetch("prompt")
    assert_nil lowering_refusal(%(g.model({ prompt: #{ESCAPE_TEXT} });))
    assert_nil lowering_refusal(%(g.ask({ prompt: #{ESCAPE_TEXT} });))
    assert_nil lowering_refusal(%(g.model({ prompt: "Report.", instructions: #{ESCAPE_TEXT} });))
    assert_equal "invalid_tool_input",
      lowering_refusal(%(g.tool({ name: "grep", input: { pattern: #{ESCAPE_TEXT}, path: "a" } });)).refusal
  end

  # A template literal can put a real U+0000 in a stage's source. The evaluator
  # builds that outer graph, but the kernel refuses the stage as `invalid_script`.
  # The static reader must report the same refusal.
  def test_a_stage_source_carrying_a_real_nul_is_refused_as_the_kernel_refuses_it
    script = <<~JS
      const greps = ["app/models/user.rb", "app/models/team.rb"].map(path => g.tool({ name: "grep", input: { path, pattern: "full_name" } }));
      g.parallel(greps);
      g.script({ results: greps, script: `
        const read = g.tool({ name: "read_file", input: { path: "app/models/user.rb" } });
        g.script({ results: [read], script:\u0000});
      ` });
    JS
    assert_includes script, "\u0000", "the source itself carries the codepoint"
    assert_equal %w[invalid_script invalid_script], refused(script).values_at("refusal", "loud")
  end

  private

    def refused(script)
      scored = Scoring.score(Objectives.find("O2"), script: script, params: {}, tool_names: Tools::NAMES)
      refute scored["valid_first"], "#{script[0, 200]}: #{scored.slice("graph").inspect}"
      scored
    end

    # The kernel's refusal of what `script` built: a compose call's at the top level, over the
    # round's set; a stage's with `stage:`, over the set a branch inherits.
    def lowering_refusal(script, stage: false)
      built = evaluate(script)
      flunk "#{built.refusal}: #{built.detail}" unless built.built?
      Shape.lowering_refusal(built.steps, stage ? Shape.branch_names(Tools::NAMES) : Tools::NAMES, stage: stage)
    end

    # The refusal's code and the script key of the step its sentence names.
    def refused_step(script, stage: false)
      refusal = lowering_refusal(script, stage: stage)
      flunk "expected a refusal for #{script}" if refusal.nil?
      [refusal.refusal, JSON.parse(refusal.detail.lines.drop(1).join).sole.fetch("step")]
    end

    def tool_input_bound = Nexus::SizeBounds.fetch(Nexus::StepBounds::TOOL_INPUT_BOUND)
    def source_bound = Nexus::Compose::Evaluator::MAX_SOURCE_BYTES

    def grep = %(g.tool({ name: "grep", input: { pattern: "x", path: "a" } }))
    def greps(count) = %(for (let i = 0; i < #{count}; i++) #{grep};\n)

    # A batch over the kernel's byte bound whose every step is within its own.
    def oversized
      per = Nexus::StepBounds::MAX_TASKS_PAYLOAD_BYTES / 128
      %(const big = "x".repeat(#{per});\nfor (let i = 0; i < 130; i++) g.tool({ name: "grep", input: { pattern: big, path: "a" } });\n)
    end
end
