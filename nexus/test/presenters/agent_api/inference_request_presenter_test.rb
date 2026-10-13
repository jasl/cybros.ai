require "test_helper"

class AgentAPI::InferenceRequestPresenterTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
    DevModelLane.ensure_enabled!(@account)
    selection = DevModelLane.selection(
      workload: "text_generation", account: @account
    )
    @inference_request = InferenceRequest.create!(
      account: @account,
      workspace: workspaces(:shared),
      creating_user: @member,
      workload: selection.workload
    )
    @invocation = DevModelLane.create_invocation!(
      inference_request: @inference_request, selection: selection
    )
    @first = attempt(ordinal: 1, settlement_state: "settled")
    @latest = attempt(ordinal: 2, settlement_state: "pending")
    @invocation.terminalize(
      status: "timed_out", reason_key: "deadline_passed", at: Time.current
    )
  end

  test "the full read never substitutes an earlier attempt receipt" do
    old_receipt = receipt(@first, error_code: "old_provider_error")
    receipt_sql = []
    subscriber = lambda do |*, payload|
      sql = payload[:sql].to_s
      if sql.include?('FROM "usage_records"') && !payload[:cached]
        receipt_sql << sql
      end
    end

    projection = ActiveSupport::Notifications.subscribed(
      subscriber, "sql.active_record"
    ) do
      AgentAPI::InferenceRequestPresenter.full(@inference_request.reload)
    end

    result = projection.fetch(:result)
    assert_nil result[:usage]
    assert_nil result[:timing]
    assert_equal({ "code" => "deadline_passed" }, result.fetch(:error))
    assert receipt_sql.any? { |sql| sql.include?('"usage_records"."account_id"') },
      "the receipt identity query must enter through the account-prefixed index"
    refute_equal old_receipt.public_id, result.dig(:usage, "usage_record_public_id")

    latest_receipt = receipt(@latest, error_code: "current_provider_error")
    projection = AgentAPI::InferenceRequestPresenter.full(@inference_request.reload)

    assert_equal latest_receipt.public_id,
      projection.dig(:result, :usage, "usage_record_public_id")
  end

  private

    def attempt(ordinal:, settlement_state:)
      ModelInvocationAttempt.create!(
        account: @account,
        model_invocation: @invocation,
        ordinal: ordinal,
        admission_shape: "admitted_free",
        status: "timed_out",
        settlement_state: settlement_state,
        terminal_at: Time.current,
        deadline_at: 10.minutes.from_now,
        consumer_public_id: @member.public_id,
        payer_public_id: @member.public_id
      )
    end

    def receipt(attempt, error_code:)
      UsageRecord.create!(
        account: @account,
        idempotency_key: "#{@invocation.internal_creation_key}:#{attempt.ordinal}",
        model_invocation_public_id: @invocation.public_id,
        attempt_ordinal: attempt.ordinal,
        consumer_user_public_id: @member.public_id,
        payer_user_public_id: @member.public_id,
        workspace_public_id: @inference_request.workspace.public_id,
        inference_request_public_id: @inference_request.public_id,
        provider_id: @invocation.provider_id,
        catalog_model_ref: @invocation.model_ref,
        wire_model_id: @invocation.model_ref,
        workload: @invocation.workload,
        purpose: @invocation.purpose,
        service_class: @invocation.service_class,
        admission_shape: "admitted_free",
        status: "failed",
        error_code: error_code,
        recorded_at: Time.current,
        cost_amount: BigDecimal(0)
      )
    end
end
