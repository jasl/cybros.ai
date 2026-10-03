require "test_helper"

# The per-subject cumulative cache (Stage 4 item 7): moves with the receipt,
# dies with its subject, and never poisons completeness over a costless
# failure. The real-chain once-per-receipt invariant lives in record_test.
class ModelUsageSummaryTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @selection = DevModelLane.selection(
      workload: "text_generation", account: @account
    )
    @one_shot = OneShot.create!(
      account: @account, workspace: workspaces(:shared), creating_user: @member,
      workload: @selection.workload
    )
  end

  test "increments accumulate across the subject's receipts, money included" do
    ModelUsageSummary.increment_for_usage_record(
      build_receipt(input_tokens: 100, output_tokens: 10, total_tokens: 110,
        cost_amount: BigDecimal("0.1"))
    )
    ModelUsageSummary.increment_for_usage_record(
      build_receipt(attempt_ordinal: 2, status: "failed", input_tokens: 40)
    )

    summary = ModelUsageSummary.find_by!(subject_kind: "one_shot", subject_id: @one_shot.id)
    assert_equal 2, summary.request_count
    assert_equal 140, summary.input_tokens
    assert_equal 110, summary.total_tokens
    assert_equal BigDecimal("0.1"), summary.cost_amount
    assert_equal @account.id, summary.account_id
  end

  test "a costless failure counts vacuously known; a costless success does not" do
    ModelUsageSummary.increment_for_usage_record(build_receipt(status: "failed"))
    ModelUsageSummary.increment_for_usage_record(
      build_receipt(attempt_ordinal: 2, admission_shape: "unmetered")
    )

    projection = projection_for(@one_shot)
    assert_equal 2, projection.fetch("request_count")
    assert_equal false, projection.fetch("cost_complete"),
      "an unmetered success keeps the aggregate honest, exactly as PublicUsage reads one receipt"

    ModelUsageSummary.delete_all
    ModelUsageSummary.increment_for_usage_record(build_receipt(status: "failed"))
    assert_equal true, projection_for(@one_shot).fetch("cost_complete"),
      "a pre-request failure with unresolvable pricing must not poison completeness forever"
  end

  test "an abandonment with unknown money keeps the summary incomplete" do
    ModelUsageSummary.increment_for_usage_record(
      build_receipt(status: UsageRecord::ABANDONED, cost_amount: nil, cost_unit: nil)
    )

    projection = projection_for(@one_shot)
    assert_equal 1, projection.fetch("request_count")
    assert_equal false, projection.fetch("cost_complete")
    assert_equal "0.0", projection.fetch("cost_amount")
  end

  test "a receipt without a standing subject is a quiet no-op" do
    ModelUsageSummary.increment_for_usage_record(build_receipt(one_shot_public_id: nil))
    ModelUsageSummary.increment_for_usage_record(
      build_receipt(idempotency_key: "summary-test:2", one_shot_public_id: SecureRandom.uuid_v7)
    )

    assert_equal 0, ModelUsageSummary.count,
      "no subject row, no dangling summary — the receipt itself still carries attribution"
  end

  test "the projection is zeros when nothing was recorded, and PublicUsage's vocabulary" do
    projection = projection_for(@one_shot)

    assert_equal 0, projection.fetch("request_count")
    assert_equal true, projection.fetch("cost_complete"), "vacuously true for zero requests"
    assert_equal "0.0", projection.fetch("cost_amount")
    assert_nil projection["cache_hit_rate"], "no input, no rate — compacted away"
    assert_equal %w[cache_creation_tokens cache_read_tokens cost_amount cost_complete
                    input_tokens output_tokens reasoning_tokens request_count total_tokens
                    uncached_input_tokens],
      projection.keys.sort
  end

  test "the projection's cache arithmetic speaks over real numbers" do
    ModelUsageSummary.increment_for_usage_record(build_receipt(
      input_tokens: 200, cache_read_tokens: 50, output_tokens: 10,
      total_tokens: 210, cost_amount: BigDecimal("0.25")
    ))

    projection = projection_for(@one_shot)
    assert_equal 150, projection.fetch("uncached_input_tokens")
    assert_equal 0.25, projection.fetch("cache_hit_rate")
    assert_equal "0.25", projection.fetch("cost_amount")
    assert_equal true, projection.fetch("cost_complete")
  end

  test "a pending-settlement attempt fences reclamation until its receipt lands" do
    invocation = DevModelLane.create_invocation!(
      one_shot: @one_shot, selection: @selection
    )
    ModelInvocationAttempt.create!(
      account: @account, model_invocation: invocation, ordinal: 1,
      admission_shape: "priced", deadline_at: 10.minutes.from_now,
      settlement_state: "pending"
    )
    ModelInvocation.where(id: invocation.id).update_all(status: "completed")
    OneShot.where(id: @one_shot.id).update_all(tombstoned_at: 31.days.ago)

    OneShots::Reap.call(batch: 10)
    assert OneShot.exists?(@one_shot.id),
      "a pending attempt still owns a future receipt; reclaiming it would discard " \
      "the accounting evidence and its subject summary"

    ModelInvocationAttempt.where(model_invocation_id: invocation.id)
      .update_all(settlement_state: "settled")
    OneShots::Reap.call(batch: 10)
    assert_not OneShot.exists?(@one_shot.id), "settled, the fence lifts"
  end

  test "the summary dies with its subject in the drain" do
    ModelUsageSummary.increment_for_usage_record(build_receipt)
    assert_equal 1, ModelUsageSummary.count

    OneShots::Drain.call(one_shot_ids: [@one_shot.id])

    assert_equal 0, ModelUsageSummary.count, "a subject-keyed rollup never dangles"
    assert_equal 1, UsageRecord.count, "accounting truth is untouched by the teardown"
  end

  private

    def projection_for(one_shot)
      ModelUsageSummary.public_projection(subject_kind: "one_shot", subject_id: one_shot.id)
    end

    def build_receipt(**overrides)
      UsageRecord.create!(
        account: @account, idempotency_key: "summary-test:#{SecureRandom.hex(6)}",
        model_invocation_public_id: SecureRandom.uuid_v7,
        attempt_ordinal: 1, consumer_user_public_id: @member.public_id,
        one_shot_public_id: @one_shot.public_id, workspace_public_id: workspaces(:shared).public_id,
        provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation",
        purpose: "one_shot_attempt", service_class: "interactive",
        admission_shape: "priced", status: "succeeded", recorded_at: Time.current,
        **overrides
      )
    end
end
