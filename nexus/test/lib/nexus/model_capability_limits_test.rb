require "test_helper"

# The three readings of one struct: the HARD bound (input or the shared
# window), the ADVISORY one (a subscription's effective cap, below the
# hard window), and the PLANNING bound the assembler fits to and the
# compaction arms read (cache audit 2026-09-16, prefix-4) — advisory
# first, else hard, so a lane fitted short of its window compacts at the
# fit instead of sliding under it.
class Nexus::ModelCapabilityLimitsTest < ActiveSupport::TestCase
  test "the planning bound is the advisory bound where one exists, else the hard one" do
    codex = LimitsOf.bounds(advisory: 272_000, hard: 1_050_000)
    assert_equal 272_000, codex.planning_input_bound
    assert_equal 1_050_000, codex.input_token_bound

    plain = LimitsOf.bounds(hard: 8_192)
    assert_equal 8_192, plain.planning_input_bound
    assert_nil plain.advisory_input_bound

    assert_nil LimitsOf.bounds.planning_input_bound, "a windowless lane plans to nothing"
  end
end
