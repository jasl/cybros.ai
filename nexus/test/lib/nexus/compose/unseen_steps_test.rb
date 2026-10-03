require "test_helper"

# STEPS THE KERNEL CANNOT SEE. A compose script places its steps while the builder runs it, and the
# builder hands back what it placed when the run returns. The rest of an async function after its
# first `await`, and a `.then` callback, run after that — a step either places reaches no graph —
# so such a script is refused whole, never built from the half it placed in time. A script that
# places no step at all is refused too: the kernel would have nothing to run.
class Nexus::Compose::UnseenStepsTest < ActiveSupport::TestCase
  Evaluator = Nexus::Compose::Evaluator

  DEFERRED = "a script that awaits or defers builds nothing the kernel can see: write the steps as " \
    "statements, in order; the kernel runs them."
  NOTHING = "the script built no step: write the steps as statements, in order; the kernel runs them."

  def build(script, params = {}) = Evaluator.call(script: script, params: params, tool_names: %w[read_file])

  test "a step placed after an await or in a callback refuses the whole script by name" do
    [
      '(async () => { g.tool({ name: "read_file" }); await null; g.model({ prompt: "lost" }); })();',
      'async function main() { await null; g.model({ prompt: "lost" }); } main();',
      'g.tool({ name: "read_file" }); Promise.resolve().then(() => g.model({ prompt: "lost" }));',
      'const later = g.model; g.tool({ name: "read_file" }); Promise.resolve().then(() => later({ prompt: "lost" }));',
      'async (g, params) => { g.tool({ name: "read_file" }); await null; g.model({ prompt: "lost" }); }',
    ].each do |script|
      result = build(script)
      assert_equal [:script_error, DEFERRED], [result.refusal, result.detail], script
      assert_empty result.steps, script
    end
  end

  # The continuations run inside the evaluation's own time bound, so one that never ends is the
  # script's timeout, never a job that hangs waiting to read what it placed.
  test "a continuation that never ends times the script out" do
    assert_equal :script_timed_out,
      build('(async () => { await null; while (true) {} })(); g.tool({ name: "read_file" });').refusal
  end

  # A script that is one quoted string is refused around these same words, naming the quotes
  # (`EvaluatorTest`).
  test "a script that places no step is refused with the repair" do
    ['async function main() { await agent("x"); } main();',
     'if (params.files.length > 0) g.tool({ name: "read_file" });'].each do |script|
      result = build(script, { "files" => [] })
      assert_equal [:script_error, NOTHING], [result.refusal, result.detail], script
    end
  end

  test "a promise that places nothing, and a promise of a handle, leave the script as written" do
    result = build(<<~JS)
      Promise.resolve().then(() => 1);
      const read = g.tool({ name: "read_file" });
      Promise.resolve(read);
      g.model({ prompt: "summarize", results: [read] });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal %w[tool model], result.steps.map { |step| step.keys.first }
  end
end
