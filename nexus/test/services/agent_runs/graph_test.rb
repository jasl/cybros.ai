require "test_helper"

# The one settlement formula: `uncertain` is a failure word the formula must know, or every policy
# would hold the loop for a person — an absorb would not resolve, a propagate would not skip, and a
# race loser settled `uncertain` would park the loop on an answered question.
class AgentRuns::GraphTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def settlement(status, on_failure, failure_resolution = nil, race_settled: false)
    AgentRuns::Graph.settlement(
      status: status, on_failure: on_failure, failure_resolution: failure_resolution,
      race_settled: race_settled
    )
  end

  test "uncertain settles by its policy exactly as failed does" do
    assert_equal :pending, settlement("uncertain", "halt"), "a halt waits for a person"
    assert_equal :skip, settlement("uncertain", "propagate"), "a propagate cascades the skip"
    assert_equal :resolved, settlement("uncertain", "absorb"),
      "absorb resolves without a stamp: the settlement is DERIVED from the policy (review 2026-09-08 change 3)"
    assert_equal :resolved, settlement("uncertain", "halt", "abandoned"), "a person's abandon resolves"
    assert_equal :resolved, settlement("uncertain", "halt", nil, race_settled: true),
      "a loser of a settled race resolves on the same derived branch"
    assert_equal :skip, settlement("canceled", "absorb"), "a stop's cancel skips whatever the policy"
    assert_equal :resolved, settlement("canceled", "halt", "canceled"), "the person's cancel is the one that resolves"
  end

  test "the failure words read alike under every policy" do
    %w[failed timed_out uncertain].each do |word|
      AgentRunTask::ON_FAILURE_POLICIES.each do |policy|
        assert_equal settlement("failed", policy), settlement(word, policy), "#{word} under #{policy}"
      end
    end
  end

  test "an uncertain halt loser of a settled race is absorbed by the race, and an open one is not" do
    agent_run = seed(
      parallel(model("fast"), model("late"), until: "any", key: "race", losers: "run_out"),
      model("after")
    )
    late = agent_run.agent_run_tasks.find_by!(node_key: "late")
    race = agent_run.agent_run_tasks.find_by!(node_key: "race")
    assert_equal "halt", late.on_failure
    # Written past the machine on purpose: the formula is pure over the
    # columns and the edge, and the machine's own edges are pinned in the
    # state-machine test.
    AgentRunTask.where(id: late.id).update_all(status: "uncertain", error_key: "tool_uncertain")

    assert_not AgentRuns::Graph.settled_race_loser?(late.reload), "an open race cannot absorb"
    assert_equal :pending, AgentRuns::Graph.settlement_of(late)

    AgentRunTask.where(id: race.id).update_all(status: "completed")
    assert AgentRuns::Graph.settled_race_loser?(late.reload)
    assert_equal :resolved, AgentRuns::Graph.settlement_of(late),
      "the question it raced to answer has an answer"
  end

  test "join_outcomes renders an unresolved uncertain member by its own word and an absorbed one as absorbed" do
    row = Struct.new(:status, :on_failure, :failure_resolution, :outgoing_edges)
    unresolved = row.new("uncertain", "halt", nil, [])
    abandoned = row.new("uncertain", "halt", "abandoned", [])
    absorbed = row.new("failed", "absorb", nil, [])
    assert_equal({ "u" => "uncertain", "a" => "abandoned", "b" => "absorbed" },
      AgentRuns::Graph.join_outcomes("u" => unresolved, "a" => abandoned, "b" => absorbed),
      "the derived settlement keeps the word a reader of the summary always saw")
  end
end
