require "test_helper"

class Nexus::Compose::EvaluatorRecoveryTest < ActiveSupport::TestCase
  test "a caught member failure leaves later fallback tasks in the enclosing sequence" do
    result = Nexus::Compose::Evaluator.call(script: <<~JS, params: { "paths" => [] })
      g.model({ key: "before", prompt: "Prepare the review" });
      try {
        g.parallel([() => {
          if (!params.paths.length) throw new Error("No candidate files");
          g.tool({ name: "read_file", input: { path: params.paths[0] } });
        }]);
      } catch (_) {
        g.model({ key: "fallback", prompt: "Explain that no candidate matched" });
      }
      g.model({ key: "after", prompt: "Finish the report" });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal %w[before fallback after], model_keys(result)
    assert_equal [1, 8, 10], result.lines
  end

  test "a nested member failure discards its unfinished group and restores the outer sequence" do
    result = Nexus::Compose::Evaluator.call(script: <<~JS)
      g.model({ key: "before", prompt: "Prepare the review" });
      try {
        g.parallel([() => {
          g.tool({ name: "read_file", input: { path: "partial.rb" } });
          g.parallel([() => {
            g.tool({ name: "read_file", input: { path: "nested.rb" } });
            throw new Error("Use the fallback review");
          }]);
        }]);
      } catch (_) {
        g.model({ key: "fallback", prompt: "Review from the supplied context" });
      }
      g.model({ key: "after", prompt: "Finish the report" });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal %w[before fallback after], model_keys(result)
    assert_equal [1, 11, 13], result.lines
  end

  test "a refused quorum leaves the placed tasks available for an all group" do
    result = Nexus::Compose::Evaluator.call(script: <<~JS, params: { "required" => 3 })
      const a = g.tool({ key: "a", name: "read_file", input: { path: "a.rb" } });
      const b = g.tool({ key: "b", name: "read_file", input: { path: "b.rb" } });
      try {
        g.parallel([a, b], { until: params.required });
      } catch (_) {
        g.parallel([a, b]);
      }
      g.model({ key: "report", prompt: "Summarize both files" });
    JS

    assert_predicate result, :built?, result.inspect
    assert_equal %w[parallel model], result.steps.map { |step| step.keys.sole }
    assert_equal %w[a b], result.steps.first.fetch("parallel").map { |step| step.fetch("tool").fetch("key") }
    assert_equal "report", result.steps.last.fetch("model").fetch("key")
    assert_equal [{ "line" => 6, "members" => [1, 2] }, 8], result.lines
  end

  def model_keys(result)
    result.steps.map { |step| step.fetch("model").fetch("key") }
  end
end
