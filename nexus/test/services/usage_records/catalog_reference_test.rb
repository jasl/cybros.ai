require "test_helper"

class UsageRecords::CatalogReferenceTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
  end

  test "a full length model alias survives result settlement and usage rollup" do
    assert_settlement_and_rollup(
      catalog_ref: "dev/#{"m" * 128}", wire_model: "mock-priced"
    )
  end

  test "an accepted wire model longer than 128 characters survives result settlement" do
    assert_settlement_and_rollup(catalog_ref: "dev/long-wire", wire_model: "w" * 129)
  end

  private

    def assert_settlement_and_rollup(catalog_ref:, wire_model:)
      current = ModelCatalog.current
      entry = current.models.fetch(DevModelLane::PRICED_TEXT_MODEL).deep_dup
      entry["model_id"] = wire_model
      snapshot = current.with(models: current.models.merge(catalog_ref => entry))
      ModelCatalog::CatalogValidation.validate_change(
        snapshot.models, snapshot.selectors, catalog_ref, snapshot.providers
      )

      ModelCatalog.stub(:current, snapshot) do
        command = InferenceRequests::Create::Command.new(
          workspace: workspaces(:shared), creating_user: @human,
          workload: "text_generation",
          submitted: DevModelLane.submission_for("text_generation", model: catalog_ref),
          configuration: {},
          input: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "hello" }] }],
          upload_public_ids: [], billing_subject: nil, idempotency_key: SecureRandom.uuid
        )
        created = InferenceRequests::Create.call(command: command, port: DevModelLane.port)
        assert_predicate created, :created?
        inference_request = InferenceRequest.find_by!(public_id: created.accepted.fetch("inference_request_public_id"))
        invocation = inference_request.model_invocation
        assert_equal catalog_ref.split("/", 2).last, invocation.model_ref
        admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |item|
          item.invocation.id == invocation.id
        end
        assert_not_nil admitted

        fake_dispatch(sse_success("hello", usage: { "input_tokens" => 100, "output_tokens" => 10 })) do |adapter|
          result = ModelInvocations::ExecuteAttempt.call(attempt: admitted.attempt, host: "solid_queue")
          assert_predicate result, :applied?
          assert_equal wire_model, JSON.parse(adapter.requests.sole.fetch(:body)).fetch("model")
        end

        assert_equal "completed", invocation.reload.status
        assert_equal "settled", admitted.attempt.reload.settlement_state
        receipt = UsageRecord.find_by!(model_invocation_public_id: invocation.public_id)
        assert_equal catalog_ref, receipt.catalog_model_ref
        assert_equal wire_model, receipt.wire_model_id
        assert_equal BigDecimal("0.000065"), receipt.cost_amount

        assert_equal 1, ModelUsageRollups::BackfillHourly.call[:processed]
        buckets = ModelUsageTimeBucket.where(catalog_model_ref: catalog_ref).order(:bucket_kind)
        assert_equal %w[hour month], buckets.pluck(:bucket_kind)
        buckets.each do |bucket|
          assert_equal 1, bucket.request_count
          assert_equal 100, bucket.input_tokens
          assert_equal 10, bucket.output_tokens
          assert_equal receipt.cost_amount, bucket.cost_amount
        end
        assert_not_nil receipt.reload.hourly_rolled_up_at
        assert_equal 0, ModelUsageRollups::BackfillHourly.call[:processed]
      end
    end
end
