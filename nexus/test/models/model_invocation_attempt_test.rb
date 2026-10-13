require "test_helper"

# The Attempt is a narrow lifecycle row, not a duplicate send log.
class ModelInvocationAttemptTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared),
      creating_user: users(:owner),
      workload: "text_generation"
    )
    @invocation = DevModelLane.create_invocation!(inference_request: inference_request)
  end

  test "an unstarted attempt is valid with no evidence at all" do
    attempt = build_attempt

    assert_predicate attempt, :valid?
    attempt.save!

    assert_equal "prepared", attempt.status
    assert_equal "not_applicable", attempt.settlement_state
    refute_predicate attempt, :started?
    assert_includes ModelInvocationAttempt.active, attempt
  end

  test "ordinals are positive and unique per invocation" do
    build_attempt.save!

    refute_predicate build_attempt(ordinal: 0), :valid?
    refute_predicate build_attempt(ordinal: -1), :valid?
    assert_raises(ActiveRecord::RecordNotUnique) { build_attempt.save! }
    assert_predicate build_attempt(ordinal: 2), :valid?
  end

  test "the admission shape is closed and immutable" do
    refute_predicate build_attempt(admission_shape: "sponsored"), :valid?

    attempt = build_attempt.tap(&:save!)

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      attempt.update!(admission_shape: "admitted_free")
    end
  end

  # Every name below was a speculative snapshot or a duplicate of the live
  # send/receipt path. Keeping this assertion prevents the evidence row from
  # silently growing back into a second request log.
  test "the attempt carries none of the deleted evidence families" do
    columns = ModelInvocationAttempt.column_names

    assert_empty %w[
      conservative_maximum_rules pricing_rule_key maximum_cost_amount
      pricing_schedule pricing_schedule_shape_digest hard_bounds
      cost_unit cost_source_policy usage_reservation_public_id
      usage_record_public_id usage_observation pricing_selectors
      output_manifest output_disposition output_adoption_expires_at
      continuation_artifact continuation_artifact_kind
      continuation_artifact_count continuation_artifact_digest
      credential_public_id credential_authorization_lineage_id
      credential_generation credential_expires_at credential_valid_until
      provider_condition_key provider_condition_contract_version
      provider_runtime_outcome_kind provider_runtime_outcome_at
      provider_retry_after_until
      late_evidence_expires_at terminal_accepted_at
      catalog_state_generation admitted_catalog_state_generation
      execution_host_kind http_transport_kind provider_id provider_endpoint
      wire_model_id adapter_profile_id profile_total_execution_deadline
      provider_request_id send_phase
    ] & columns
    assert_not_includes columns, "start_frozen_catalog_revision"
    assert_operator columns.length, :<=, 16
  end

  test "a started attempt carries only lifecycle state" do
    started = build_started

    assert_predicate started, :valid?
    assert_predicate started, :started?
    assert_equal "running", started.status
    assert_equal "pending", started.settlement_state
  end

  test "the parent cannot be deleted out from under its attempts" do
    build_attempt.save!

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ModelInvocation.lease_connection.execute(
        "DELETE FROM model_invocations WHERE id = #{@invocation.id}"
      )
    end
    assert_includes error.message, "RESTRICT"
  end

  private

    def build_attempt(**overrides)
      ModelInvocationAttempt.new(
        account: @invocation.account, model_invocation: @invocation,
        ordinal: 1, admission_shape: "priced",
        # Admission always stamps it (AdmitUsage), so a factory that omits it
        # builds a row no writer in this repo can produce.
        deadline_at: 10.minutes.from_now,
        **overrides
      )
    end

    def build_started(**overrides)
      build_attempt(
        provider_started_at: Time.current, status: "running", settlement_state: "pending",
        **overrides
      )
    end
end
