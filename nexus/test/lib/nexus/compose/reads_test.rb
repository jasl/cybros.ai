require "test_helper"

# THE READ RULE, over plain values: an authored step reads exactly the
# results it names, and what no step reads comes back to the caller. The
# kernel's lowering and the bench's Shape both call this module, so the
# rule is pinned here once rather than restated by either reader.
class Nexus::Compose::ReadsTest < ActiveSupport::TestCase
  Reads = Nexus::Compose::Reads
  Grammar = Nexus::Compose::Grammar

  test "a model and a script read what they name; a tool, an ask and a wait read nothing" do
    assert_equal %w[a b], Reads.of("model", %w[a b])
    assert_equal %w[a], Reads.of("script", %w[a])
    assert_equal [], Reads.of("tool", %w[a])
    assert_equal [], Reads.of("ask", %w[a])
    assert_equal [], Reads.of("wait", %w[a])
    assert_equal [], Reads.of("model", nil), "naming nothing reads the prompt alone"

    Grammar.verbs.each do |verb|
      assert_equal Grammar.compose_options(verb).include?("results"), Reads.reads?(verb), verb
    end
    assert_equal %w[model script], Grammar.verbs.select { |verb| Reads.reads?(verb) }
  end

  test "unread: named by none, no race member, nothing inside a stage, nothing an expansion replaced" do
    assert_equal %w[t1 m], Reads.unread(%w[t1 t2 m], named: %w[t2], members: [], internal: [], retired: []),
      "a step no one names comes back, the one a later step named does not"

    assert_equal %w[join], Reads.unread(%w[t1 m1 t2 m2 join], named: %w[t1 t2], members: %w[t1 m1 t2 m2],
      internal: [], retired: []), "a race nobody names comes back as its barrier, never an arm's step"

    assert_equal %w[leaf], Reads.unread(%w[s i1 i2 leaf], named: [], members: [], internal: %w[i1 i2],
      retired: %w[s]), "an expansion's final leaf crosses the boundary; its insides and the row it replaced do not"
  end
end
