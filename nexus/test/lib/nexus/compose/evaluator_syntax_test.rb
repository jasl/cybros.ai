require "test_helper"

# A script that does not parse is refused with the line, the column and that line's own text, because
# `new Function` reports a bare "SyntaxError: Invalid or unexpected token" and a model with no position
# spends rounds hunting the token. The position comes from a second parse that runs none of the source,
# so a source that closes the wrapper early still executes nothing. A SyntaxError the running script
# raises — JSON.parse on a tool's output, a RegExp built from data — is the data's failure, not the
# author's syntax, so only a source the builder's own compile refuses is `script_syntax_error`.
class Nexus::Compose::EvaluatorSyntaxTest < ActiveSupport::TestCase
  Evaluator = Nexus::Compose::Evaluator

  RESULT = { "status" => "completed", "is_error" => false, "output" => "team.rb:5: not json",
             "content" => [], "structured_content" => nil, "error" => nil }.freeze

  test "a syntax refusal names the line, the column and the line's text" do
    result = Evaluator.call(script: <<~JS.chomp, tool_names: %w[bash])
      g.tool({ name: "bash", input: { command: `git diff` }
       g.model({ prompt: "Review the patch." });
    JS

    assert_equal :script_syntax_error, result.refusal
    assert_equal %(SyntaxError: Unexpected identifier 'g' at line 2, column 2: g.model({ prompt: "Review the patch." });),
      result.detail
  end

  test "the first line is line 1 and a stage says whose script it is" do
    first = Evaluator.call(script: 'g.tool({ name: "bash" });\\ng.model({ prompt: "p" });', tool_names: %w[bash])
    assert_equal :script_syntax_error, first.refusal
    assert_equal %(SyntaxError: Invalid or unexpected token at line 1, column 26: g.tool({ name: "bash" });\\ng.model({ prompt: "p" });),
      first.detail, "a literal backslash-n between statements"

    stage = Evaluator.stage(script: "const lines = [\n  'a',\n  'b' 'c',\n];\nreturn lines;")
    assert_equal :script_syntax_error, stage.refusal
    assert_equal "SyntaxError: Unexpected string at line 3 of the g.script stage's script, column 7: 'b' 'c',",
      stage.detail
  end

  # V8 places a source left open on the wrapper's own text past it, and its message names the
  # wrapper's token (`)`, `}`, `;`) — one the author never wrote. So the refusal says what an
  # open ending means and places it at the author's last line.
  test "a source that ends open is placed at its last line, never on a token it did not write" do
    open = Evaluator.call(script: <<~JS, tool_names: %w[bash])
      g.tool({ name: "bash" });
      if (params.review) {
        g.model({ prompt: "Review." });

    JS
    assert_equal :script_syntax_error, open.refusal
    assert_equal "#{Evaluator::UNFINISHED} at line 3, column 34: g.model({ prompt: \"Review.\" });", open.detail

    stage = Evaluator.stage(script: "return [1, 2")
    assert_equal :script_syntax_error, stage.refusal
    assert_equal "#{Evaluator::UNFINISHED} at line 1 of the g.script stage's script, column 13: return [1, 2", stage.detail

    { "g.model({ prompt: 'x' }" => "( never closed",
      "g.parallel([g.model({ prompt: 'x' })" => "[ never closed",
      "g.model({ prompt: `x })" => "template never closed",
      "g.model({ prompt: 'x' +" => "operator left dangling",
      "function (g, params) {\n  g.model({ prompt: 'x' });" => "a function never closed",
      "(g, params) => {\n  g.model({ prompt: 'x' });" => "an arrow never closed" }.each do |script, why|
      [Evaluator.call(script: script, tool_names: %w[bash]), Evaluator.stage(script: script)].each do |result|
        assert_equal :script_syntax_error, result.refusal, why
        next unless result.detail.start_with?(Evaluator::UNFINISHED)

        assert_equal script.lines.last.strip, result.detail[/, column \d+: (.*)\z/, 1], why
      end
      assert_equal Evaluator::UNFINISHED, Evaluator.call(script: script, tool_names: %w[bash]).detail.partition(" at line ").first, why
    end
  end

  test "a long line is quoted around the column and the detail stays within its cap" do
    result = Evaluator.call(script: %(g.model({ prompt: "#{"x" * 300}" }) oops), tool_names: %w[bash])

    assert_equal :script_syntax_error, result.refusal
    assert_match(/\ASyntaxError: Unexpected identifier 'oops' at line 1, column 325: …x+" \}\) oops\z/, result.detail)
    assert_operator result.detail.length, :<=, 400
  end

  test "a long line with astral characters before the mistake is placed by character" do
    result = Evaluator.call(script: %(g.model({ prompt: "#{"😀" * 60}" }) oops; g.model({ prompt: "#{"z" * 200}" });),
      tool_names: %w[bash])

    assert_equal :script_syntax_error, result.refusal
    assert_match(/\ASyntaxError: Unexpected identifier 'oops' at line 1, column 85: …😀+" \}\) oops; g\.model\(\{ prompt: "z+…\z/,
      result.detail, "V8 counts each astral character twice; the author's column and the quoted text count it once")
  end

  test "a source that closes the wrapper early is refused without running" do
    escape = "g.tool({ name: 'bash' }); }); globalThis.escaped = 1; (function () {"
    loop = "}); while (true) {} (function () {"
    [escape, loop].each do |script|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      [Evaluator.call(script: script, tool_names: %w[bash]), Evaluator.stage(script: script)].each do |result|
        assert_equal :script_syntax_error, result.refusal, script
        assert_equal "SyntaxError: Single function literal required", result.detail, script
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, Evaluator::TIMEOUT_MS / 1000.0, "#{script}: the second parse ran the source"
    end

    mis_bracketed = Evaluator.call(script: <<~JS.chomp, tool_names: %w[bash])
      const a = g.model({ prompt: "a" });
      });
      [1, 2].forEach((x) => {
        g.model({ prompt: "b" + x });
    JS
    assert_equal :script_syntax_error, mis_bracketed.refusal, "a stray close balanced by a missing one is still the author's syntax"
  end

  # The builder compiles a compose script as a body of (g, params), and a stage as a body of
  # (g, params, results): the class and the position follow the mode's own compile.
  test "a compose script may name a local results; a stage may not" do
    data = Evaluator.call(script: <<~JS.chomp, params: { "x" => "{bad" }, tool_names: %w[bash])
      const results = [];
      JSON.parse(params.x);
      g.model({ prompt: "x" });
    JS
    assert_equal :script_error, data.refusal
    assert_match(/\ASyntaxError: Expected property name or '\}' in JSON/, data.detail)
    refute_includes data.detail, "results"

    real = Evaluator.call(script: <<~JS.chomp, tool_names: %w[bash])
      const files = ["a.rb", "b.rb"];
      const results = g.parallel(files.map((f) => g.tool({ name: "bash", input: { command: "cat " + f } })));
      g.model({ prompt: "Summarise both files." + });
    JS
    assert_equal :script_syntax_error, real.refusal
    assert_equal %(SyntaxError: Unexpected token '}' at line 3, column 45: g.model({ prompt: "Summarise both files." + });),
      real.detail

    stage = Evaluator.stage(script: "const results = 1;\nreturn results;")
    assert_equal :script_syntax_error, stage.refusal
    assert_equal "SyntaxError: Identifier 'results' has already been declared at line 1 of the g.script stage's script, " \
      "column 7: const results = 1;", stage.detail
  end

  test "a script written as a function is read as the function the builder calls" do
    data = Evaluator.call(script: <<~JS.chomp, params: { "x" => "{bad" }, tool_names: %w[bash])
      function (g, params) {
        JSON.parse(params.x);
        g.model({ prompt: "a" });
      }
    JS
    assert_equal :script_error, data.refusal
    assert_match(/\ASyntaxError: Expected property name or '\}' in JSON/, data.detail)

    broken = Evaluator.call(script: <<~JS.chomp, tool_names: %w[bash])
      function (g, params) {
        g.model({ prompt: "a" + });
      }
    JS
    assert_equal :script_syntax_error, broken.refusal
    assert_equal %(SyntaxError: Unexpected token '}' at line 2, column 27: g.model({ prompt: "a" + });), broken.detail,
      "the mistake inside the function, never the unnamed function the builder accepts"
  end

  test "a SyntaxError the running script raises is a script error with the engine's message" do
    parsed = Evaluator.stage(script: "const r = results[0]; return JSON.parse(r.output);", results: [RESULT])
    assert_equal :script_error, parsed.refusal
    assert_match(/\ASyntaxError: Unexpected token 'e', "team\.rb:5: not json" is not valid JSON\z/, parsed.detail)

    pattern = Evaluator.stage(script: "return { hit: new RegExp(results[0].output + '(').test('x') };", results: [RESULT])
    assert_equal :script_error, pattern.refusal
    assert_match(/\ASyntaxError: Invalid regular expression/, pattern.detail)

    built = Evaluator.stage(script: 'return new Function("return (")();')
    assert_equal :script_error, built.refusal
    assert_match(/\ASyntaxError: /, built.detail)

    composed = Evaluator.call(script: 'g.tool({ name: "bash", input: JSON.parse(params.raw) });',
      params: { "raw" => "not json" }, tool_names: %w[bash])
    assert_equal :script_error, composed.refusal
    assert_match(/\ASyntaxError: /, composed.detail)
  end
end
