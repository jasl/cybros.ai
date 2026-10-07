require "test_helper"

class Conversations::ExecutionDetails::PruneTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @account.update!(execution_details_retention_days: 90)
  end

  test "old execution disappears while question answer and landed follow-ups survive" do
    seam = completed_seam
    body(seam.variant, "prompt", "Original question 原始问题")
    body(seam.variant, "content", "Final answer 最终回答")
    body(seam.variant, "reasoning", "Private reasoning")
    round = round(seam.agent_run, "r1")
    steer(round, "Additional requirement 追加要求")
    runner_tool_row(seam.agent_run, "r2t0", metadata: { "checkpoint" => { "hash" => "old" } })

    assert_equal 1, prune[:pruned]
    assert_empty seam.agent_run.agent_run_tasks.reload
    assert_empty seam.agent_run.agent_run_edges.reload
    assert seam.agent_run.reload.details_pruned_at
    assert_nil seam.variant.content_bodies.find_by(role: "reasoning")
    assert_equal "Original question 原始问题", seam.variant.content_bodies.find_by!(role: "prompt").effective_text
    assert_equal "Final answer 最终回答", seam.variant.content_bodies.find_by!(role: "content").effective_text
    assert_equal ["Additional requirement 追加要求"],
      Conversations::RetainedSteers.messages(seam.variant.id).map { |message| message.parts.map(&:text).join }
    projection = Conversations::TurnProjection.loop_block(seam.variant)
    assert_equal "unavailable", projection.runner_effects.fetch(:status)
    assert_equal "execution_details_pruned", projection.runner_effects.fetch(:reason)
    assert_equal seam.agent_run.details_pruned_at, projection.details_pruned_at
    assert_equal 0, prune[:pruned], "a repeated cleanup is a no-op"

    history = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation.reload)
    text = history.segments.map(&:text).join("\n")
    assert_includes text, "Original question 原始问题"
    assert_includes text, "Additional requirement 追加要求"
    assert_includes text, "Final answer 最终回答"
    refute_includes text, "Private reasoning"
  end

  test "completion age excludes fresh delivered and still live execution" do
    old = completed_seam
    fresh = completed_seam
    fresh.agent_run.update!(completed_at: 1.day.ago)
    live = completed_seam
    live.agent_run.update!(status: "running", delivered_at: 100.days.ago, completed_at: nil)
    body(round(live.agent_run, "r1"), "input", "sealed independent request")
    @conversation.update!(active_turn: live.turn)

    assert_equal 1, prune[:pruned]
    assert old.agent_run.reload.details_pruned_at
    assert_nil fresh.agent_run.reload.details_pruned_at
    assert_nil live.agent_run.reload.details_pruned_at
    assert_equal live.turn.id, @conversation.reload.active_turn_id,
      "a new active turn does not prevent reclaiming an old completed turn"
  end

  test "disabled policy leaves all execution detail intact" do
    seam = completed_seam
    @account.update!(execution_details_retention_days: nil)
    assert_equal 0, prune[:scanned]
    assert_nil seam.agent_run.reload.details_pruned_at
  end

  test "unsettled work fences a loop and a full source page still advances" do
    retained = completed_seam
    invocation(retained.agent_run, status: "queued")
    reclaimable = completed_seam
    reclaimable.agent_run.update!(completed_at: 95.days.ago)

    first = prune(batch: 1)
    assert_equal 1, first[:scanned]
    assert_equal 0, first[:pruned]
    assert first.more?
    at, id, cutoff = first.cursor
    second = prune(batch: 1, after_at: at, after_id: id, cutoff_at: cutoff)
    assert_equal 1, second[:pruned]
    assert_nil retained.agent_run.reload.details_pruned_at
    assert reclaimable.agent_run.reload.details_pruned_at
  end

  test "the cutoff stays frozen across continuation hops" do
    completed_seam
    second = completed_seam
    second.agent_run.update!(completed_at: 89.days.ago)
    first = prune(batch: 1)
    at, id, cutoff = first.cursor
    travel 2.days do
      result = prune(batch: 1, after_at: at, after_id: id, cutoff_at: cutoff)
      assert_equal 0, result[:scanned]
      assert_nil second.agent_run.reload.details_pruned_at
    end
  end

  test "a direct reply drains settled model evidence while preserving its final text" do
    seam = completed_seam
    seam.agent_run.destroy!
    direct = invocation(@conversation, status: "completed")
    seam.variant.update!(model_invocation: direct)
    body(seam.variant, "prompt", "question")
    body(seam.variant, "content", "answer")
    body(direct, "request", "provider request")
    body(direct, "response", "provider response")

    assert_equal 1, prune(kind: "invocations")[:pruned]
    assert_not ModelInvocation.exists?(direct.id)
    assert_nil seam.variant.reload.model_invocation_id
    assert seam.variant.details_pruned_at
    assert_equal "answer", seam.variant.content_bodies.find_by!(role: "content").effective_text
  end

  test "regeneration after retention refuses by name while the answer remains readable" do
    seam = completed_seam
    body(seam.variant, "content", "answer")
    prune
    result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation.reload, turn_public_id: seam.turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_equal :execution_details_pruned, result.outcome
    assert_equal "answer", seam.variant.content_bodies.find_by!(role: "content").effective_text
  end

  test "fork runner_effects is unavailable rather than untouched when a later execution expired" do
    seam = completed_seam
    prune
    runner_effects = Conversations::RunnerEffectsAt.call(conversation: @conversation, position: seam.turn.position - 1)
    assert_equal({ status: "unavailable", runners: [], reason: "execution_details_pruned" }, runner_effects)
  end

  test "pending settlement retains model evidence until its receipt is complete" do
    seam = completed_seam
    model = invocation(seam.agent_run, status: "completed")
    attempt = model.attempts.create!(account: @account, ordinal: 1, admission_shape: "priced",
      deadline_at: 100.days.ago, provider_started_at: 100.days.ago,
      status: "completed", settlement_state: "pending")
    assert_equal 0, prune[:pruned]
    assert ModelInvocation.exists?(model.id)
    attempt.update!(settlement_state: "settled")
    assert_equal 1, prune[:pruned]
    assert_not ModelInvocation.exists?(model.id)
    assert_not ModelInvocationAttempt.exists?(attempt.id)
  end

  test "a fork can adopt retained text and follow-ups after execution expired" do
    seam = completed_seam
    body(seam.variant, "prompt", "question")
    body(seam.variant, "content", "answer")
    steer(round(seam.agent_run, "r1"), "follow-up")
    prune
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: seam.turn.public_id,
      variant_public_id: nil, acting_user: @human, title: "fork"
    ))
    assert result.accepted?, result.outcome.inspect
    child = result.value
    copied = child.conversation_turns.sole.active_variant
    assert_equal "answer", copied.content_bodies.find_by!(role: "content").effective_text
    assert_equal ["follow-up"], Conversations::RetainedSteers.messages(copied.id)
      .map { |message| message.parts.map(&:text).join }
    history = Conversations::ContextAssembly::ChatHistory.call(conversation: child)
    assert_includes history.segments.map(&:text).join("\n"), "follow-up"
  end

  test "a fork preparing from an old loop re-reads retained text after a concurrent prune" do
    seam = completed_seam
    body(seam.variant, "prompt", "Original question")
    body(seam.variant, "content", "Final answer")
    steer(round(seam.agent_run, "r1"), "Additional requirement")
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: nil, variant_public_id: nil,
      acting_user: @human, title: "side", side: true
    ))
    assert result.accepted?, result.outcome.inspect
    original = Conversations::RetainedSteers.method(:messages_by_variant)
    pruned = false
    interleave = lambda do |ids, **options|
      unless pruned
        pruned = true
        assert_equal 1, prune[:pruned]
      end
      original.call(ids, **options)
    end
    history = Conversations::RetainedSteers.stub(:messages_by_variant, interleave) do
      Conversations::ContextAssembly::ChatHistory.call(conversation: result.value)
    end
    assert pruned
    text = history.segments.map(&:text).join("\n")
    %w[Original Additional Final].each { |word| assert_includes text, word }
  end

  test "an inherited unsealed active first round retains detail until its request is sealed" do
    old = completed_seam
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: nil, variant_public_id: nil,
      acting_user: @human, title: "side", side: true
    ))
    assert result.accepted?
    child = result.value
    active = create_run_backed_turn(conversation: child, acting_user: @human)
    seed = round(active.agent_run, Conversations::Inputs::ApplyNext::SEED_ROUND_KEY)
    assert_equal 0, prune[:pruned]
    assert_nil old.agent_run.reload.details_pruned_at
    body(seed, "input", "sealed history")
    assert_equal 1, prune[:pruned]
    assert old.agent_run.reload.details_pruned_at
    assert_equal active.turn.id, child.reload.active_turn_id
  end

  test "a standalone loop is not pruned by conversation retention" do
    standalone = AgentRun.create!(workspace: @workspace, creating_user: @human,
      status: "completed", completed_at: 100.days.ago, approval_mode: "bypass")
    assert_equal 0, prune[:scanned]
    assert_nil standalone.reload.details_pruned_at
  end

  private

    def prune(**options)
      Conversations::ExecutionDetails::Prune.call(account: @account, batch: 20, **options)
    end

    def completed_seam
      seam = create_run_backed_turn(conversation: @conversation.reload, acting_user: @human,
        turn_status: "completed", variant_status: "completed", run_status: "completed")
      seam.agent_run.update!(completed_at: 100.days.ago)
      @conversation.reload.update!(active_turn: nil)
      seam
    end

    def round(agent_run, key)
      agent_run.agent_run_tasks.create!(node_key: key, type: AgentRunTasks::ModelTask.sti_name,
        provider_id: "dev", model_ref: "mock-text", authored_by: "kernel",
        continuation_source: AgentRuns::Tasks::Compile::ROUND)
    end

    def steer(node, text)
      message = Nexus::TextInputMessage.from_h("role" => "user", "parts" => [{ "type" => "text", "text" => text }])
      AgentRuns::Steers::Landed.record(node, [message])
    end

    def body(owner, role, text)
      result = ContentBodies::Replace.call(owner: owner, role: role, entries: [{ "text" => text }], seal: true)
      assert result.accepted?
      result.body
    end

    def invocation(host, status:)
      association = host == @conversation ? :conversation : :agent_run
      ModelInvocation.create!(association => host, creating_user: @human,
        internal_creation_key: SecureRandom.uuid, provider_id: "dev", model_ref: "mock-text",
        request_options: {}, admission_deadline_seconds: 60, status: status,
        terminal_at: (100.days.ago if status == "completed"),
        terminal_event_recorded_at: (100.days.ago if status == "completed"))
    end
end
