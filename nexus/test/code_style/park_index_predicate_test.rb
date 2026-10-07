require "test_helper"

# THE SWEEP'S INDEX AND THE ENGINE'S VOCABULARY, PINNED EQUAL.
#
# `index_agent_run_tasks_on_park_frontier` is a PARTIAL index, and its
# predicate names the statuses a live park can sit in. A migration may
# not read an application constant, so the list is a literal — which
# means the day a status is added to or removed from the vocabulary, the
# predicate silently stops matching and the once-a-minute sweep degrades
# to a sequential scan of the highest-cardinality table in the plane, on
# a table that gains a row per tool call.
#
# This exact failure already happened once for the neighbouring axis:
# `WidenAgentRunParkIndex` exists because a predicate naming one node
# TYPE could not serve a sweep over two. A comment did not prevent it, so
# this test is here instead.
class ParkIndexPredicateTest < ActiveSupport::TestCase
  INDEX = "index_agent_run_tasks_on_park_frontier".freeze

  def predicate
    definition = ApplicationRecord.connection.select_value(
      "SELECT indexdef FROM pg_indexes WHERE indexname = #{ApplicationRecord.connection.quote(INDEX)}"
    )
    refute_nil definition, "#{INDEX} does not exist; the park sweep has no index to use"
    definition
  end

  def test_the_predicate_names_exactly_the_statuses_a_live_park_can_hold
    found = AgentRunTask::STATUSES.select { |status| predicate.include?("'#{status}'") }

    # The started parks AND the row resting for an approver, which sits on the same clock: the
    # sweep's whole set.
    assert_equal AgentRunTask::SWEPT_STATUSES.sort, found.sort,
      "the partial index predicate and AgentRunTask::SWEPT_STATUSES have drifted; " \
      "a park in an unlisted status is invisible to the sweep's index. Predicate: #{predicate}"
  end

  # The other half of the predicate: without it the index would cover
  # every node ever parked, settled ones included, for no reader.
  def test_the_predicate_still_narrows_to_an_armed_park
    assert_includes predicate, "await_started_at IS NOT NULL"
  end
end
