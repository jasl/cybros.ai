require "test_helper"

# The authoring contract, checked rather than asserted. The compose
# builder and the append door are two halves of one contract, and the
# way that contract fails is SILENTLY: a field the door reads that the
# builder cannot place, or a door-only field the builder learns to
# forge. This test is the tripwire, over the step tree.
class Nexus::Compose::GrammarTest < ActiveSupport::TestCase
  Grammar = Nexus::Compose::Grammar
  Step = AgentLoops::Tasks::Step

  test "the grammar's verbs are the door's verbs, and every field the door reads is named once" do
    assert_equal Step::VERBS, Grammar.verbs
    Grammar.verbs.each do |verb|
      assert_equal Step::WIRE_FIELDS.fetch(verb).sort - ["tool_call_id"], Grammar.fields_for(verb).sort,
        "#{verb}: the door's wire fields are compose's options plus the door's own — nothing else"
    end
    assert_equal [], Grammar.verbs.flat_map { |verb| Grammar.compose_options(verb) & Grammar.door_options(verb) },
      "a field cannot be both a compose option and a door-only one"
  end

  # The OTHER direction, and the one a text scan cannot prove: for every
  # verb, a built script carries every compose option — a script can SET
  # each one, except the `key` the builder mints on a race (the `until:
  # "any"` fan below carries it) — and every door-only field is refused at
  # the line rather than dropped.
  test "the builder places every compose option and refuses every door-only field" do
    result = Nexus::Compose::Evaluator.call(script: <<~JS, tool_names: %w[read_file])
      const t = g.tool({ name: "read_file", input: { path: "a" }, key: "t", timeout_ms: 1000, after: [] });
      g.model({ prompt: "p", model: "dev/mock-text", tools: ["read_file"], instructions: "be brief", key: "m", after: [t], results: [t] });
      g.ask({ prompt: "which?", options: ["Postgres", "MySQL"], multi: false, key: "a", timeout_ms: 60000, after: [t] });
      g.wait({ task: "r1t0", agent_loop: "01900000-0000-7000-8000-000000000001", key: "w", timeout_ms: 1000, after: [t] });
      g.script({ script: "return params", params: { answer: 42 }, key: "s", after: [t], results: [t] });
      g.parallel([g.tool({ name: "read_file" })], { until: "any" });
      g.model({ prompt: "after" });
    JS
    assert_predicate result, :built?, result.inspect

    placed = result.steps.first(5).to_h { |step| step.to_a.sole }
    placed["parallel"] = result.steps[5].except("parallel")
    Grammar.verbs.each do |verb|
      missing = Grammar.compose_options(verb) - placed.fetch(verb).keys
      assert_empty missing, "a #{verb} option the door reads that no script can set: #{missing.join(", ")}"
    end

    examples = { "tool" => 'g.tool({ name: "read_file", %s })', "model" => 'g.model({ prompt: "p", %s })',
                 "ask" => 'g.ask({ prompt: "p", %s })',
                 "wait" => 'g.wait({ task: "r1t0", %s })',
                 "script" => 'g.script({ script: "return null", %s })',
                 "parallel" => 'g.parallel([g.tool({ name: "read_file" })], { %s })' }
    Grammar.verbs.each do |verb|
      Grammar.door_options(verb).each do |field|
        refused = Nexus::Compose::Evaluator.call(script: format(examples.fetch(verb), "#{field}: 1"),
          tool_names: %w[read_file])
        assert_equal :script_error, refused.refusal, "#{verb}.#{field} must be refused, not dropped"
        assert_match(/is not (a compose|an) option|unknown option/, refused.detail, "#{verb}.#{field}")
      end
    end
  end

  # A RACE'S KEY IS CARRIED, NEVER WRITTEN: every built race names its barrier so a later step's
  # `after`/`results` can name it, so `key` is a compose option of a group — and the builder alone
  # sets it, refusing it from the script like any option it does not take.
  test "a race's key is a compose option the builder mints and a script cannot write" do
    assert_includes Grammar.compose_options("parallel"), "key"
    refute_includes Grammar.door_options("parallel"), "key"
    minted = Nexus::Compose::Evaluator.call(script: <<~JS, tool_names: %w[read_file])
      const race = g.parallel([g.tool({ name: "read_file" }), g.tool({ name: "read_file" })], { until: "any" });
      g.model({ prompt: "p", results: [race] });
    JS
    assert_predicate minted, :built?, minted.inspect
    assert_equal "parallel-1", minted.steps.first.fetch("key")
    written = Nexus::Compose::Evaluator.call(
      script: 'g.parallel([g.tool({ name: "read_file" })], { until: "any", key: "race" });', tool_names: %w[read_file]
    )
    assert_equal :script_error, written.refusal
    assert_includes written.detail, %(g.parallel: unknown option "key". The one option is until.)
  end

  # THE WHEN WORD IS ON THE CALL: `detached` is the door's per-step word, never compose's, and the
  # deleted per-step spelling is refused at the line with the one sentence that teaches the call's
  # `wait`.
  test "detached is a door option on every task verb, and run_in_background is refused with the call's word" do
    %w[tool model ask wait script].each do |verb|
      assert_includes Grammar.door_options(verb), "detached", verb
      refute_includes Grammar.compose_options(verb), "detached", verb
      refute_includes Grammar.fields_for(verb), "run_in_background", verb
    end
    refused = Nexus::Compose::Evaluator.call(
      script: 'g.tool({ name: "read_file", run_in_background: true });', tool_names: %w[read_file]
    )
    assert_equal :script_error, refused.refusal
    assert_includes refused.detail, "run_in_background: is not an option. The whole compose call runs in the background unless " \
      "you call it with wait: true; steps run in the order you write them, and work nothing should wait on " \
      "goes in its own call or beside the rest in one g.parallel([...]).", refused.detail
  end

  test "the door's authorable kinds are the leaf verbs that build a task" do
    leaves = [Step::Tool.new(name: "x"), Step::Model.new, Step::Ask.new,
      Step::Wait.new(task: "existing"), Step::Script.new(script: "return null")]
    assert_equal Step::VERBS - ["parallel"], leaves.map(&:verb)
    assert_equal %w[await_task model_task script_task tool_task],
      leaves.map(&:kind).uniq.sort,
      "a barrier is the kernel's row, never a kind a client authors"
  end

  test "per-step lifetime and wake are refused with the whole call as their supported location" do
    examples = {
      "tool" => 'g.tool({ name: "read_file", %s });',
      "model" => 'g.model({ prompt: "review", %s });',
      "ask" => 'g.ask({ prompt: "Which?", %s });',
      "wait" => 'g.wait({ task: "r1t0", %s });',
      "script" => 'g.script({ script: "return null", %s });',
      "parallel" => 'g.parallel([g.tool({ name: "read_file" })], { %s });',
    }
    { "lifetime" => "turn", "wake" => "passive" }.each do |field, value|
      examples.each do |verb, script|
        assert_includes Grammar.door_options(verb), field
        refute_includes Grammar.compose_options(verb), field
        result = Nexus::Compose::Evaluator.call(script: format(script, "#{field}: #{value.to_json}"), tool_names: %w[read_file])
        assert_equal :script_error, result.refusal
        assert_includes result.detail, "set #{field} on the whole compose call, outside the script"
      end
    end
  end
end
