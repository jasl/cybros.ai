require "test_helper"

class InferenceRequests::ReclaimedUsageTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @billing_key = "reclaimed-#{SecureRandom.hex(6)}"
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    DevModelLane.ensure_enabled!(@account)
  end

  test "retry receipts settle and roll up exactly once after their InferenceRequest is physically reclaimed" do
    opened = UsageBudgets::Open.call(
      actor: users(:owner), target: @human, starts_at: 1.minute.ago,
      amount: "10", operation_key: SecureRandom.uuid
    )
    assert_predicate opened, :opened?
    budget = opened.budget
    inference_request = create_inference_request
    invocation = inference_request.model_invocation
    first = admit(invocation)

    transient = json_response(
      503, { "error" => { "message" => "overloaded" } }, headers: { "retry-after" => "0" }
    )
    assert_predicate execute(first, transient), :requeued?
    second = admit(invocation)
    assert_equal [1, 2], [first.ordinal, second.ordinal]
    assert_predicate execute(second, sse_success("recovered")), :applied?
    assert_equal "completed", invocation.reload.status
    assert_equal %w[settled settled], invocation.attempts.order(:ordinal).pluck(:settlement_state)

    receipts = UsageRecord.where(model_invocation_public_id: invocation.public_id).order(:attempt_ordinal)
    assert_equal [1, 2], receipts.pluck(:attempt_ordinal)
    assert_equal %w[failed succeeded], receipts.pluck(:status)
    expected_cost = BigDecimal("0.0000055")
    assert_equal [nil, expected_cost], receipts.pluck(:cost_amount)
    assert_equal 2, ModelUsageSummary.find_by!(subject_kind: "inference_request", subject_id: inference_request.id).request_count
    receipt_ids = receipts.pluck(:public_id)
    immutable_receipts = receipt_snapshots(receipts)

    # A second accepted request shares the sealed input fragments, so reclaiming
    # the first must leave the other request's actual content readable.
    retained = create_inference_request
    shared_fragments = inference_request.content_bodies.sole.content_body_entries.pluck(:content_fragment_id)
    assert_equal shared_fragments,
      retained.content_bodies.sole.content_body_entries.pluck(:content_fragment_id)
    assert_predicate InferenceRequests::Tombstone.call(inference_request: inference_request), :accepted?
    assert_equal 0, InferenceRequests::Reap.call(batch: 10)[:reaped]
    travel(InferenceRequest::RETENTION_PERIOD + 1.day) do
      assert_equal 1, InferenceRequests::Reap.call(batch: 10)[:reaped]
    end

    assert_not InferenceRequest.exists?(inference_request.id)
    assert_not ModelInvocation.exists?(invocation.id)
    assert_empty ModelInvocationAttempt.where(model_invocation_id: invocation.id)
    assert_not ModelUsageSummary.exists?(subject_kind: "inference_request", subject_id: inference_request.id)
    assert_equal ["same sealed request"], retained.content_bodies.sole.reload.parts.map(&:text)
    assert_equal shared_fragments.sort, ContentFragment.where(id: shared_fragments).order(:id).pluck(:id)
    assert_equal immutable_receipts, receipt_snapshots(receipts)
    assert_equal [inference_request.public_id], receipts.reorder(nil).distinct.pluck(:inference_request_public_id)
    assert_equal [@workspace.public_id], receipts.reorder(nil).distinct.pluck(:workspace_public_id)
    assert_equal [@human.public_id], receipts.reorder(nil).distinct.pluck(:consumer_user_public_id)
    assert_equal [@human.public_id], receipts.reorder(nil).distinct.pluck(:payer_user_public_id)
    assert_equal [inference_request.billing_subject_public_id], receipts.reorder(nil).distinct.pluck(:billing_subject_public_id)
    assert_equal [@billing_key], receipts.reorder(nil).distinct.pluck(:billing_subject_key)

    settled = UsageRecords::SettleSpend.call
    assert_equal [2, 1, 0], [settled[:settled], settled[:charged], settled[:unknown_cost]]
    assert_equal expected_cost, budget.reload.debited_amount
    charge = budget.entries.where(kind: "charge").sole
    assert_equal receipt_ids.last, charge.usage_record_public_id
    assert_equal expected_cost, charge.amount
    assert_equal 2, receipts.where.not(spend_settled_at: nil).count

    assert_equal 2, ModelUsageRollups::BackfillHourly.call[:processed]
    assert_rollups(expected_cost)
    assert_equal 2, receipts.where.not(hourly_rolled_up_at: nil).count
    assert_equal immutable_receipts, receipt_snapshots(receipts)

    replay = UsageRecords::SettleSpend.call
    assert_equal [0, 0, 0], [replay[:settled], replay[:charged], replay[:unknown_cost]]
    assert_equal 0, ModelUsageRollups::BackfillHourly.call[:processed]
    assert_equal 1, budget.entries.where(kind: "charge").count
    assert_equal expected_cost, budget.reload.debited_amount
    assert_rollups(expected_cost)
    assert_equal immutable_receipts, receipt_snapshots(receipts)
  end

  private

    def create_inference_request
      command = InferenceRequests::Create::Command.new(
        workspace: @workspace, creating_user: @human, workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation", model: DevModelLane::PRICED_TEXT_MODEL),
        configuration: {},
        input: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "same sealed request" }] }],
        upload_public_ids: [], billing_subject: @billing_key, idempotency_key: SecureRandom.uuid
      )
      result = InferenceRequests::Create.call(command: command, port: DevModelLane.port)
      assert_predicate result, :created?, result.refusal.inspect
      InferenceRequest.find_by!(public_id: result.accepted.fetch("inference_request_public_id"))
    end

    def admit(invocation)
      admission = ModelInvocations::AdmitQueuedWork.call.admitted.find { |entry| entry.invocation.id == invocation.id }
      assert_not_nil admission
      clear_enqueued_jobs
      admission.attempt
    end

    def execute(attempt, response)
      fake_dispatch(response) do |adapter|
        result = ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
        assert_equal 1, adapter.requests.length, "each admitted ordinal sends exactly once"
        result
      end
    end

    def receipt_snapshots(receipts)
      receipts.reload.map do |receipt|
        receipt.attributes.except("spend_settled_at", "hourly_rolled_up_at", "updated_at")
      end
    end

    def assert_rollups(expected_cost)
      %w[hour month].each do |kind|
        buckets = ModelUsageTimeBucket.where(billing_subject_key: @billing_key, bucket_kind: kind).order(:status)
        assert_equal %w[failed succeeded], buckets.pluck(:status)
        assert_equal [1, 1], buckets.pluck(:request_count)
        assert_equal [0, 2], buckets.pluck(:input_tokens)
        assert_equal [0, 3], buckets.pluck(:output_tokens)
        assert_equal [0, 5], buckets.pluck(:total_tokens)
        assert_equal [BigDecimal(0), expected_cost], buckets.pluck(:cost_amount)
        assert_equal [1, 1], buckets.pluck(:cost_known_request_count)
        assert_equal [@workspace.public_id], buckets.reorder(nil).distinct.pluck(:workspace_public_id)
        assert_equal [@human.public_id], buckets.reorder(nil).distinct.pluck(:payer_user_public_id)
      end
    end
end
