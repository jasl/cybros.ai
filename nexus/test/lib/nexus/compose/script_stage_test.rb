require "test_helper"

class Nexus::Compose::ScriptStageTest < ActiveSupport::TestCase
  Evaluator = Nexus::Compose::Evaluator

  test "a script reads ordered settled values and can return null without building work" do
    result = Evaluator.stage(script: "return results.map(r => r.structured_content)",
      results: [{ "structured_content" => { "files" => [] } }, { "structured_content" => nil }])
    assert_predicate result, :value?
    assert_equal [{ "files" => [] }, nil], result.value
    empty = Evaluator.stage(script: "return null")
    assert_predicate empty, :value?
    assert_nil empty.value
  end

  test "results drive a dynamic fan followed by a reducer with handles lowered to keys" do
    result = Evaluator.stage(script: <<~JS, results: [{ "structured_content" => { "files" => %w[a.rb b.rb] } }])
      const checks = results[0].structured_content.files.map(path =>
        g.tool({ name: "inspect", input: { path } }));
      g.parallel(checks);
      g.script({ results: checks, script: "return results.map(r => r.output)" });
    JS
    assert_predicate result, :steps?, result.detail
    assert_equal %w[tool-1 tool-2], result.steps.last.dig("script", "results")
    assert_equal %w[a.rb b.rb], result.steps.first.fetch("parallel").map { |entry| entry.dig("tool", "input", "path") }
  end

  test "ambiguous and non-JSON outcomes refuse the entire computation" do
    ["", "return undefined", "return Promise.resolve(1)", "return NaN", "return {x: undefined}",
     "return {x: () => 1}", "return [, 1]", "const a = {}; a.self = a; return a",
     'g.tool({name: "read"}); return null', 'return (g) => g.tool({name: "read"})'].each do |source|
      result = Evaluator.stage(script: source)
      refute_predicate result, :built?, source
      assert_empty result.steps
    end
  end

  # A stage's continuation runs after the stage returned what it placed or computed, so a step it
  # places reaches no graph: the stage is refused whole, whether it placed steps in time or none.
  test "a stage that places a step after an await is refused whole" do
    sentence = "a script that awaits or defers builds nothing the kernel can see: write the steps as " \
      "statements, in order; the kernel runs them."
    ['g.model({prompt: "a"}); (async () => { await null; g.model({prompt: "b"}); })();',
     '(async () => { await null; g.model({prompt: "b"}); })();',
     '(async () => { await null; g.model({prompt: "b"}); })(); return 1;'].each do |source|
      result = Evaluator.stage(script: source)
      assert_equal [:script_error, sentence], [result.refusal, result.detail], source
      assert_empty result.steps, source
    end
  end

  # A STAGE'S EXPANSION ENDS ON ONE READABLE LEAF: the append door refuses one that ends on a fan or a
  # race (`script_requires_single_result`), so the builder refuses it first, with the repair. A group
  # whose one member ends on a step ends on that step, and the door takes it; the compose call's own
  # top level may still end on a group.
  test "a stage that ends on a group is refused with the repair, one that ends on one step is not" do
    sentence = "Error: A g.script stage must end with ONE step such as g.model or g.script, not a g.parallel([...]); " \
      "add a step after the group whose results: name what it reads."
    ['g.parallel([g.tool({name: "read"}), g.tool({name: "read"})]);',
     'g.parallel([g.tool({name: "read"}), g.tool({name: "read"})], {until: "any"});',
     'g.parallel([g.tool({name: "read"})], {until: 1});',
     'g.parallel([[g.tool({name: "read"}), g.parallel([g.tool({name: "read"}), g.tool({name: "read"})])]]);'].each do |source|
      result = Evaluator.stage(script: source)
      assert_equal :script_error, result.refusal, source
      assert_equal sentence, result.detail, source
      assert_empty result.steps, source
    end

    ['g.parallel([g.tool({name: "read"})]);',
     'g.parallel([[g.tool({name: "read"}), g.model({prompt: "p"})]], {until: "all"});',
     'g.parallel([g.tool({name: "read"}), g.tool({name: "read"})]); g.model({prompt: "p"});'].each do |source|
      assert_predicate Evaluator.stage(script: source), :steps?, source
    end
    assert_predicate Evaluator.call(script: 'g.parallel([g.tool({name: "read"}), g.tool({name: "read"})]);'), :built?,
      "the compose call's top level may end on a group"
  end

  test "compose references require leaf handles and preserve declared ordering" do
    result = Evaluator.call(script: <<~JS)
      const a = g.tool({name: "read"});
      const b = g.tool({name: "read"});
      const c = g.model({prompt: "check", after: [a], results: [b, a]});
      g.parallel([a, b, c]);
    JS
    assert_predicate result, :built?, result.detail
    assert_equal %w[tool-2 tool-1], result.steps.first.fetch("parallel").last.dig("model", "results")
    ['g.model({prompt:"p",results:["tool-1"]})',
     'const a=g.tool({name:"read"});g.model({prompt:"p",results:[a,a]})',
     'const p=g.parallel([g.tool({name:"read"})]);g.script({script:"return null",results:[p]})'].each do |source|
      refute_predicate Evaluator.call(script: source), :built?, source
    end
    group = Evaluator.call(script: 'const p=g.parallel([g.tool({name:"read"})]);g.script({script:"return null",results:[p]})')
    assert_equal %(Error: g.script: results names an "all" group, which is not one step; list its steps instead: results: [a, b].),
      group.detail
  end

  # A RACE IS ONE STEP: a stage names it by the Array its g.parallel returned and reads what it
  # selected; the reference crosses as the race's minted key.
  test "a stage reads a race by its handle, as the key the builder minted" do
    result = Evaluator.call(script: <<~JS)
      const race = g.parallel([g.tool({name: "read"}), g.tool({name: "read"})], {until: "any"});
      g.script({results: [race], script: "return results[0].output;"});
    JS
    assert_predicate result, :built?, result.detail
    assert_equal "parallel-1", result.steps.first.fetch("key")
    assert_equal ["parallel-1"], result.steps.last.dig("script", "results")
  end
end
