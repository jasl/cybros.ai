require "test_helper"

class ModelInvocations::ConversationCostLimitTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @account.update!(cost_unit: "USD")
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: @agent, cost_limit: "0")
  end

  test "zero rejects a priced direct reply before any attempt or receipt without fallback" do
    declare_tools!(@agent, tools: [], default_model: "dev/mock-priced", fallback_models: ["dev/mock-text"])
    turn, invocation = direct_reply

    assert_no_difference [-> { ModelInvocationAttempt.count }, -> { UsageRecord.count }] do
      assert_empty ModelInvocations::AdmitQueuedWork.call.admitted
      Conversations::Turns::Converge.call
    end

    assert_equal ["failed", Conversation::COST_LIMIT_REACHED],
      invocation.reload.values_at(:status, :failure_reason_key)
    assert_equal "failed", turn.reload.status
    assert_equal 1, turn.variants.count, "a runtime cost refusal does not switch to a free fallback"
    assert_equal Conversation::COST_LIMIT_REACHED,
      @conversation.event_items.where(item_type: "turn_status").order(:sequence).last.payload.fetch("failure_reason_key")
  end

  test "an explicit regeneration after clearing the cap reuses the direct reply turn" do
    turn, invocation = direct_reply
    ModelInvocations::AdmitQueuedWork.call
    Conversations::Turns::Converge.call
    original = turn.reload.active_variant
    @conversation.reload.update!(cost_limit: nil)
    assert_equal "failed", invocation.reload.status, "changing the setting does not restart work"

    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    candidate = turn.variants.order(:position).last
    attempt = ModelInvocations::AdmitQueuedWork.call.admitted.sole.attempt
    assert_predicate apply_via(attempt, sse_success("recovered")), :applied?
    Conversations::Turns::Converge.call

    assert_equal "completed", turn.reload.status
    assert_equal candidate.id, turn.active_variant_id
    assert_equal "failed", original.reload.status
    assert_equal 1, @conversation.turns.count
    assert_equal 1, UsageRecord.where(conversation_public_id: @conversation.public_id).count
  end

  test "a receipt-backed known subtotal gates the next attempt at equality without refunding history" do
    @conversation.update!(cost_limit: "1")
    first_turn, = direct_reply
    attempt = ModelInvocations::AdmitQueuedWork.call.admitted.sole.attempt
    assert_predicate apply_via(attempt, sse_success("paid answer")), :applied?
    Conversations::Turns::Converge.call
    receipt = UsageRecord.find_by!(conversation_public_id: @conversation.public_id)
    assert_operator receipt.cost_amount, :>, 0
    @conversation.reload.update!(cost_limit: receipt.cost_amount)
    assert @conversation.cost_limit_reached?

    deleted = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
      conversation: @conversation.reload, turn_public_id: first_turn.public_id, acting_user: @human
    ))
    assert_predicate deleted, :accepted?, deleted.outcome.inspect
    _turn, invocation = direct_reply
    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted
    assert_equal Conversation::COST_LIMIT_REACHED, invocation.reload.failure_reason_key
    assert_empty invocation.attempts
    assert_equal receipt.cost_amount, ModelUsageSummary.find_by!(subject_kind: "conversation", subject_id: @conversation.id).cost_amount
    detail = AgentAPI::ConversationPresenter.full(@conversation.reload, acting_user: @human)
    assert_equal true, detail.fetch(:cost_limit_reached)
    assert_equal receipt.cost_amount.to_s("F"), detail.dig(:usage_summary, "cost_amount")
  end

  test "free and unknown-price calls retain their own price shape at an exhausted cap" do
    %w[mock-text mock-unmetered].zip(%w[admitted_free unmetered]).each do |model_ref, shape|
      turn, invocation = direct_reply(model_ref: model_ref)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.sole
      assert_equal shape, admitted.attempt.admission_shape
      assert_predicate apply_via(admitted.attempt, sse_success("allowed")), :applied?
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      assert_nil invocation.reload.failure_reason_key
    end
    detail = AgentAPI::ConversationPresenter.full(@conversation.reload, acting_user: @human)
    assert_equal true, detail.fetch(:cost_limit_reached)
    assert_equal false, detail.dig(:usage_summary, "cost_complete")
  end

  test "a different conversation and standalone inference are not charged to this cap" do
    other = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, invocation = direct_reply(conversation: other)
    assert_equal invocation.id, ModelInvocations::AdmitQueuedWork.call.admitted.sole.invocation.id
    assert_equal "priced", admitted_attempt(model: DevModelLane::PRICED_TEXT_MODEL).admission_shape
    assert @conversation.cost_limit_reached?
  end

  test "lowering the cap leaves an already admitted attempt free to settle its actual cost" do
    @conversation.update!(cost_limit: "1")
    turn, = direct_reply
    attempt = ModelInvocations::AdmitQueuedWork.call.admitted.sole.attempt
    @conversation.reload.update!(cost_limit: "0")
    assert_predicate apply_via(attempt, sse_success("already admitted")), :applied?
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_operator UsageRecord.find_by!(conversation_public_id: @conversation.public_id).cost_amount, :>, 0
  end

  private

    def direct_reply(conversation: @conversation, model_ref: "mock-priced")
      post_input!(conversation.reload, acting_user: @human, text: "question", kind: "direct_reply",
        provider_id: "dev", model_ref: model_ref)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
      turn = conversation.turns.order(:position).last
      [turn, turn.active_variant.model_invocation]
    end
end
