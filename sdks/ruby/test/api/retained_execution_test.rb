require "test_helper"
require_relative "../support/conversation_fixtures"

class RetainedExecutionTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_a_retained_variant_preserves_its_text_and_reports_unavailable_execution_details
    fixture = contract.fetch("valid_turns_fixture")
    turn = fixture.fetch("turns").find { |row| row["active_variant"] }
    variant = contract.fetch("valid_pruned_variant_fixture").fetch("variant")
    page = chat([[200, {}, fixture.merge("turns" => [turn.merge("active_variant" => variant)])]]).turns.list
    actual = page.items.first.active_variant

    assert_equal variant.fetch("details_pruned_at"), actual.details_pruned_at
    assert_equal variant.fetch("content"), actual.content
    assert_predicate actual.runner_effects, :unavailable?
    refute_predicate actual.runner_effects, :untouched?
    assert_equal "execution_details_pruned", actual.runner_effects.reason
    assert_equal contract.fetch("runner_effects_fixtures").fetch("unavailable"), actual.runner_effects.to_h.transform_keys(&:to_s)
  end

  def test_run_overview_keeps_its_identity_after_detail_collection
    fixture = CybrosAgentTest::ContractFixtures.pack("runs.json").fetch("valid_request_run_fixture")
    row = fixture.fetch("run").merge("tasks" => [], "details_pruned_at" => "2026-09-29T00:00:00Z")
    run = workspace([[200, {}, { "run" => row }]]).run(row.fetch("public_id")).fetch

    assert_equal row.fetch("public_id"), run.public_id
    assert_equal "2026-09-29T00:00:00Z", run.details_pruned_at
    assert_empty run.tasks
  end

  def test_collected_detail_requests_preserve_the_gone_error_without_retry
    refusal = CybrosAgentTest::ContractFixtures.pack("runs.json").fetch("expired_detail_error_fixture")
    run = workspace([[refusal.fetch("status"), refusal.fetch("headers"), refusal.fetch("body")]])
      .run("01900000-0000-7000-8000-0000000000b1")

    error = assert_raises(CybrosAgent::Api::InvalidRequest) { run.task("work") }

    assert_equal "execution_details_pruned", error.code
    assert_equal 1, @transport.requests.length
  end
end
