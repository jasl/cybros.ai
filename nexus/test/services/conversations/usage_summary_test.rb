require "test_helper"

class Conversations::UsageSummaryTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    @conversation = Conversation.create!(workspace: @workspace,
      creating_user: @human, answering_user: @agent)
  end

  test "an unused conversation reports zero cumulative usage without inventing occupancy" do
    document = AgentAPI::ConversationPresenter.full(@conversation, acting_user: @human)
    usage = document.fetch(:usage_summary)

    assert_equal 0, usage.fetch("request_count")
    assert_equal [0, 0, 0], usage.values_at("input_tokens", "output_tokens", "total_tokens")
    assert_equal "0.0", usage.fetch("cost_amount")
    assert_equal true, usage.fetch("cost_complete")
    assert_nil usage["cache_hit_rate"]
    assert_nil document[:context]
  end

  test "direct and loop replies accumulate their own receipts independently of current occupancy" do
    direct = complete_direct_reply(model_ref: "mock-priced", usage: {
      "input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14,
      "input_tokens_details" => { "cached_tokens" => 6 },
      "output_tokens_details" => { "reasoning_tokens" => 2 },
    })
    declare_tools!(@agent)
    _turn, agent_run = complete_loop_reply(usage: {
      "input_tokens" => 20, "output_tokens" => 6, "total_tokens" => 26,
      "input_tokens_details" => { "cached_tokens" => 4 },
      "output_tokens_details" => { "reasoning_tokens" => 1 },
    })

    usage = summary
    assert_equal 2, usage.fetch("request_count")
    assert_equal [30, 10, 20, 10, 3, 40], usage.values_at(
      "input_tokens", "cache_read_tokens", "uncached_input_tokens",
      "output_tokens", "reasoning_tokens", "total_tokens"
    )
    assert_equal 0.333333, usage.fetch("cache_hit_rate")
    assert_equal true, usage.fetch("cost_complete")
    assert_operator usage.fetch("cost_amount").to_d, :>, 0
    assert_equal "USD", usage.fetch("cost_unit")
    assert_equal 26, AgentAPI::ConversationPresenter.full(@conversation.reload, acting_user: @human).dig(:context, :used_tokens),
      "occupancy describes the newest request, not all requests this conversation paid for"

    expected = [direct.active_variant.model_invocation.public_id, agent_run.model_invocations.sole.public_id]
    assert_equal expected.sort, receipts.order(:model_invocation_public_id).pluck(:model_invocation_public_id)
  end

  test "unmetered usage makes an exact-zero total incomplete without losing its tokens" do
    complete_direct_reply
    assert_equal "0.0", summary.fetch("cost_amount")
    assert_equal true, summary.fetch("cost_complete")

    complete_direct_reply(model_ref: "mock-unmetered", usage: {
      "input_tokens" => 7, "output_tokens" => 5,
    })

    usage = summary
    assert_equal 2, usage.fetch("request_count")
    assert_equal [9, 8, 17], usage.values_at("input_tokens", "output_tokens", "total_tokens")
    assert_equal "0.0", usage.fetch("cost_amount")
    assert_equal false, usage.fetch("cost_complete"), "unknown money is not a second free call"
    assert_equal ["admitted_free", "unmetered"], receipts.order(:id).pluck(:admission_shape)
    assert_nil receipts.order(:id).last.cost_amount
  end

  test "receipt attribution and the summary roll back together and a retry increments once" do
    turn = start_direct_reply(model_ref: "mock-priced")
    attempt = direct_attempt(turn.active_variant.model_invocation)
    built = build(attempt)
    assert_predicate built, :built?, built.refusal.inspect
    started = start(attempt)
    outcome = fake_dispatch(sse_success("answer")) do
      ModelInvocations::Dispatch.call(attempt: started.attempt,
        context: started.context, request: built.request)
    end

    ApplicationRecord.transaction(requires_new: true) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
      assert_equal 1, summary.fetch("request_count")
      raise ActiveRecord::Rollback
    end
    assert_empty receipts
    assert_equal "pending", attempt.reload.settlement_state
    assert_equal 0, summary.fetch("request_count")

    first = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    replay = UsageRecords::Record.call(attempt: attempt.reload, outcome: outcome, status: "succeeded")
    assert_equal first.id, replay.id
    assert_equal 1, receipts.count
    assert_equal [1, 2, 3, 5], summary.values_at("request_count", "input_tokens", "output_tokens", "total_tokens")
  end

  test "a refused direct reply and its fallback both contribute to the conversation total" do
    declare_tools!(@agent, tools: [], default_model: "dev/mock-priced", fallback_model: "dev/mock-unmetered")
    turn = start_direct_reply(model_ref: "mock-priced")
    refused = turn.active_variant
    assert_predicate apply_via(direct_attempt(refused.model_invocation), sse_refused("Cannot answer",
      usage: { "input_tokens" => 7, "output_tokens" => 1 })), :applied?
    Conversations::Turns::Converge.call
    fallback = turn.conversation_turn_variants.order(:position).last
    assert_equal ["failed", "running", "fallback", "mock-unmetered"],
      [refused.reload.status, turn.reload.status, fallback.source, fallback.model_ref]
    assert_equal 1, summary.fetch("request_count")

    assert_predicate apply_via(direct_attempt(fallback.model_invocation), sse_success("fallback answer",
      usage: { "input_tokens" => 11, "output_tokens" => 3 })), :applied?
    Conversations::Turns::Converge.call

    assert_equal ["completed", fallback.id], turn.reload.values_at(:status, :active_variant_id)
    assert_equal [2, 18, 4, 22], summary.values_at("request_count", "input_tokens", "output_tokens", "total_tokens")
    assert_equal false, summary.fetch("cost_complete")
    assert_operator summary.fetch("cost_amount").to_d, :>, 0
    assert_equal [refused.model_invocation.public_id, fallback.model_invocation.public_id].sort,
      receipts.order(:model_invocation_public_id).pluck(:model_invocation_public_id)
  end

  test "a real compaction summary contributes its model call to the conversation total" do
    complete_direct_reply
    compacted = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: @conversation.reload, acting_user: @human, model: "dev/mock-priced"
    ))
    assert_predicate compacted, :accepted?, compacted.outcome.inspect
    turn = compacted.value.turn
    agent_run = turn.active_variant.agent_run
    assert_equal "compaction_summary", turn.kind
    assert_equal @conversation.public_id, agent_run.conversation_public_id
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("the compacted history", usage: {
      "input_tokens" => 13, "output_tokens" => 4,
    }))
    Conversations::Turns::Converge.call

    assert_equal ["completed", "completed"], [turn.reload.status, agent_run.reload.status]
    assert_equal [2, 15, 7, 22], summary.values_at("request_count", "input_tokens", "output_tokens", "total_tokens")
    assert_equal true, summary.fetch("cost_complete")
    assert_operator summary.fetch("cost_amount").to_d, :>, 0
    assert_equal @conversation.public_id,
      UsageRecord.find_by!(model_invocation_public_id: agent_run.model_invocations.sole.public_id).conversation_public_id
  end

  test "a fork inherits readable history but starts its own usage total" do
    turn = complete_direct_reply
    parent_usage = summary
    fork = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id,
      variant_public_id: nil, acting_user: @human, title: "fork"
    ))
    assert_predicate fork, :accepted?, fork.outcome.inspect
    child = fork.value
    assert_equal "Mock: answer", child.timeline.entries(surface: :timeline).sole.turn.active_variant
      .content_bodies.find_by!(role: "content").effective_text
    assert_equal 0, summary(child).fetch("request_count")

    complete_direct_reply(conversation: child, usage: { "input_tokens" => 11, "output_tokens" => 7 })

    assert_equal parent_usage, summary
    assert_equal 1, summary(child).fetch("request_count")
    assert_equal 18, summary(child).fetch("total_tokens")
    assert_equal 1, UsageRecord.where(conversation_public_id: child.public_id).count
  end

  test "execution retention keeps cumulative usage and physical conversation collection removes only its cache" do
    direct = complete_direct_reply
    direct_invocation = direct.active_variant.model_invocation
    declare_tools!(@agent)
    _turn, agent_run = complete_loop_reply
    before = summary
    receipt_ids = receipts.pluck(:public_id).sort
    invocation_ids = [direct_invocation.id, *agent_run.model_invocations.pluck(:id)]
    @account.update!(execution_details_retention_days: 90)
    # Advance only the retention clocks installed by completed execution.
    assert direct_invocation.terminal_at
    assert agent_run.reload.completed_at
    direct_invocation.update!(terminal_at: 100.days.ago)
    agent_run.update!(completed_at: 100.days.ago)

    assert_equal 1, Conversations::ExecutionDetails::Prune.call(account: @account, batch: 10)[:pruned]
    assert_equal 1, Conversations::ExecutionDetails::Prune.call(
      account: @account, batch: 10, kind: "invocations"
    )[:pruned]
    assert_not ModelInvocation.where(id: invocation_ids).exists?
    assert agent_run.reload.details_pruned_at
    assert direct.active_variant.reload.details_pruned_at
    assert_equal before, summary
    assert_equal receipt_ids, receipts.pluck(:public_id).sort

    result = Conversations::Tombstone.call(conversation: @conversation.reload)
    assert_predicate result, :accepted?, result.outcome.inspect
    Conversation.where(id: @conversation.id).update_all(
      tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago
    )
    assert_equal 1, Conversations::Reap.call(batch: 10).value[:reaped]

    assert_not Conversation.exists?(@conversation.id)
    assert_not ModelUsageSummary.exists?(subject_kind: "conversation", subject_id: @conversation.id)
    assert_equal receipt_ids, receipts.pluck(:public_id).sort,
      "the retained receipts still identify the physically deleted conversation"
  end

  test "a late provider receipt after terminal apex undo still belongs to the original conversation" do
    declare_tools!(@agent)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, model_ref: "mock-priced")
    schedule_loop!(agent_run)
    attempt = loop_attempt(agent_run)
    built = build(attempt)
    assert_predicate built, :built?, built.refusal.inspect
    started = start(attempt)
    outcome = fake_dispatch(sse_success("late answer")) do
      ModelInvocations::Dispatch.call(
        attempt: started.attempt, context: started.context, request: built.request
      )
    end

    canceled = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation.reload, acting_user: @human
    ))
    assert_predicate canceled, :accepted?, canceled.outcome.inspect
    AgentRuns::ConvergeTerminalSteps.call
    schedule_loop!(agent_run)
    Conversations::Turns::Converge.call
    assert_equal "canceled", turn.reload.status
    assert_equal "canceled", agent_run.reload.status
    assert_equal "pending", attempt.reload.settlement_state
    assert_equal 0, summary.fetch("request_count")

    deleted = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human
    ))
    assert_predicate deleted, :accepted?, deleted.outcome.inspect
    assert_not ConversationTurn.exists?(turn.id)
    assert_nil agent_run.reload.conversation_turn_variant_id

    applied = ModelInvocations::ApplyResult.call(attempt: attempt.reload, outcome: outcome)
    assert_equal ModelInvocations::ApplyResult::DISCARDED, applied.outcome
    receipt = receipts.sole
    assert_equal "discarded", receipt.status
    assert_equal @conversation.public_id, receipt.conversation_public_id
    assert_equal 1, summary.fetch("request_count")
    assert_equal 5, summary.fetch("total_tokens")
    assert_operator receipt.cost_amount, :>, 0
    assert_equal receipt.cost_amount.to_s("F"), summary.fetch("cost_amount")

    assert_no_difference -> { receipts.count } do
      ModelInvocations::ApplyResult.call(attempt: attempt.reload, outcome: outcome)
    end
    assert_equal 1, summary.fetch("request_count"), "replaying the late result never counts it twice"
  end

  private

    def summary(conversation = @conversation)
      AgentAPI::ConversationPresenter.full(conversation.reload, acting_user: @human).fetch(:usage_summary)
    end

    def receipts = UsageRecord.where(conversation_public_id: @conversation.public_id)

    def complete_direct_reply(conversation: @conversation, model_ref: "mock-text",
                              usage: { "input_tokens" => 2, "output_tokens" => 3 })
      turn = start_direct_reply(conversation: conversation, model_ref: model_ref)
      assert_predicate apply_via(direct_attempt(turn.active_variant.model_invocation), sse_success("answer", usage: usage)), :applied?
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      turn
    end

    def start_direct_reply(conversation: @conversation, model_ref: "mock-text")
      post_input!(conversation.reload, acting_user: @human, text: "question", kind: "direct_reply",
        provider_id: "dev", model_ref: model_ref)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
      turn = conversation.conversation_turns.order(:position).last
      assert turn.active_variant.model_invocation, "a tool-less reply owns its invocation directly"
      turn
    end

    def direct_attempt(invocation)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find { |row| row.invocation.id == invocation.id }
      assert admitted, "the reply was admitted"
      clear_enqueued_jobs
      admitted.attempt
    end

    def complete_loop_reply(usage: { "input_tokens" => 2, "output_tokens" => 3 })
      turn, agent_run = materialize_loop_reply!(@conversation.reload, agent: @human)
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("answer", usage: usage))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      assert_equal "completed", agent_run.reload.status
      [turn, agent_run]
    end
end
