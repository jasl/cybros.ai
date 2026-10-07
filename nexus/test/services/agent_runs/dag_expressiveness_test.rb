require "test_helper"

class AgentRuns::DagExpressivenessTest < ActiveSupport::TestCase
  # A repository scan (a) feeds a review (c), while an independent check (b)
  # and that same scan feed a report (d). These are the existing authoring
  # alternatives; waiting for a task and reading its result are distinct:
  # position hands a step its waits, and a step reads what it names.
  test "a foreground fan: the review names both producers and waits for both" do
    result = compile([
      parallel(tool("a"), tool("b")),
      parallel(model("c", "results" => %w[a b]), model("d", "results" => %w[a b])),
      model("finish", "results" => %w[c d]),
    ])

    assert_equal [%w[a c], %w[a d], %w[b c], %w[b d], %w[c finish], %w[d finish]], edges(result)
    assert_equal %w[a b], results(result, "c")
    assert_equal %w[a b], results(result, "d")
    assert_equal %w[c d], results(result, "finish")
    assert_empty %w[c d finish].filter_map { |key| reads(result, key) }, "nothing is read by position"
  end

  test "a foreground review can start after the scan but its follower waits for the review" do
    result = compile([
      parallel([tool("a"), model("c", "results" => ["a"])], tool("b")), model("d", "results" => %w[c b]),
    ])

    assert_equal [%w[a c], %w[b d], %w[c d]], edges(result)
    assert_equal ["a"], results(result, "c")
    assert_equal %w[c b], results(result, "d")
  end

  test "a detached review permits overlapping dependencies while starting from its own brief" do
    result = compile([
      parallel([tool("a"), detached(model("c", "lifetime" => "turn"))], tool("b")), model("d", "results" => %w[a b]),
    ])

    assert_equal [%w[a c], %w[a d], %w[b d]], edges(result)
    assert_nil reads(result, "c")
    assert_nil results(result, "c")
    assert_equal %w[a b], results(result, "d")

    review = result.nodes.find { |node| node.fetch("node_key") == "c" }
    assert review.fetch("detached")
    assert_equal "branch", review.fetch("continuation_source")
    assert_equal "turn", review.fetch("lifetime")
    assert_equal "d", result.tip.mainline.key
    assert_equal ["d"], result.tip.waits.map(&:key)
    assert_empty result.tip.reads
  end

  private

    def compile(steps)
      result = AgentRuns::Tasks::Compile.call(steps,
        AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::ROUND))
      assert_predicate result, :valid?, result.errors.inspect
      result
    end

    def edges(result)
      result.edges.map { |edge| [edge.fetch("from_key"), edge.fetch("to_key")] }.sort
    end

    def reads(result, key)
      result.nodes.find { |node| node.fetch("node_key") == key }["input_from_node_keys"]
    end

    def results(result, key)
      result.nodes.find { |node| node.fetch("node_key") == key }["result_from_node_keys"]
    end
end
