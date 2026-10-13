require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationRecoveryReadsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_point_read_projects_the_displayed_and_running_candidates_in_one_request
    turn = contract.fetch("valid_turns_fixture").fetch("turns").first
    running = contract.fetch("valid_fallback_variant_fixture").fetch("variant")
      .merge("status" => "running", "active" => false)
    result = chat([[200, {}, { "turn" => turn.merge("running_variant" => running) }]])
      .turns.fetch(TURN_ID, include_hidden: true)

    assert_equal "#{PATH}/turns/#{TURN_ID}", request.fetch(:path)
    assert_equal({ "include_hidden" => true }, request.fetch(:params))
    assert_equal TURN_ID, result.public_id
    assert_equal running.fetch("public_id"), result.running_variant.public_id
    assert_equal result.active_variant.public_id, result.running_variant.origin_variant_public_id
    refute_predicate result.running_variant, :active?
    assert_predicate result.active_variant, :active?
  end

  def test_materialization_reads_original_identity_and_only_treats_not_found_as_absent
    fixture = contract.fetch("valid_materialization_fixture")
    input_id = fixture.dig("materialization", "input_public_id")
    result = chat([[200, {}, fixture]]).inputs.materialization(input_id)
    assert_equal "#{PATH}/inputs/#{input_id}/materialization", request.fetch(:path)
    assert_equal VARIANT_ID, result.variant_public_id
    assert_nil result.run_public_id
    assert_nil chat([[404, {}, { "error" => { "code" => "not_found" } }]]).inputs.materialization("pending")
    assert_raises(CybrosAgent::Api::Conflict) do
      chat([[409, {}, { "error" => { "code" => "busy" } }]]).inputs.materialization("input-1")
    end
  end
end
