require "test_helper"

# THE ONE SHAPE A COMPACTION POLICY TAKES, on a round or a profile: three
# modes, and a delegate's tool name.
class Nexus::CompactionPolicyTest < ActiveSupport::TestCase
  test "the modes, and a delegate needs its tool" do
    assert Nexus::CompactionPolicy.well_formed?({ "mode" => "kernel" })
    assert Nexus::CompactionPolicy.well_formed?({ "mode" => "off" })
    assert Nexus::CompactionPolicy.well_formed?({ "mode" => "delegate", "tool_name" => "summarize_history" })
    assert_not Nexus::CompactionPolicy.well_formed?({ "mode" => "delegate" })
    assert_not Nexus::CompactionPolicy.well_formed?({ "mode" => "prune" })
    assert_not Nexus::CompactionPolicy.well_formed?("kernel")
    assert_not Nexus::CompactionPolicy.well_formed?(nil)
  end
end
