require "test_helper"

class Conversations::ForkPrefixTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @actor = Speakers::Resolve.member(account: @account, user: @human)
  end

  test "an idle side pins its inherited tail against every content verb and a direct pointer write" do
    turn, original, sibling = settled_turn
    child = fork(side: true)
    before = history(child)

    assert_content_frozen(turn, sibling)
    assert_equal original.id, turn.reload.active_variant_id
    assert_equal before, history(child)

    original.settle(status: "completed")
    assert_equal before, history(child), "settlement of the same pointer remains valid"
  end

  test "deleting a plain fork's source apex does not unfreeze the inherited predecessor" do
    predecessor, _, sibling = settled_turn
    apex, = settled_turn
    child = fork(turn: apex)
    before = history(child)

    deleted = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
      conversation: @conversation, turn_public_id: apex.public_id, acting_user: @human
    ))
    assert_predicate deleted, :accepted?
    assert_content_frozen(predecessor, sibling)
    assert_equal before, history(child)

    adopted = child.conversation_turns.sole
    assert_predicate edit(adopted, conversation: child), :accepted?, "the adopted boundary is independently editable"
    child.destroy!
    assert_predicate edit(predecessor.reload), :accepted?, "reaping the last descendant releases its prefix"
  end

  test "a side freezes a held loop's tail while retry and convergence continue to change its rounds" do
    settled, = settled_turn
    seam = loop_turn
    run_round(seam.agent_run, json_response(400, { "error" => "bad" }))
    AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", seam.agent_run.reload.status
    assert_equal "failed", seam.turn.reload.status
    assert_nil @conversation.reload.active_turn_id

    child = fork(side: true)
    before = history(child)
    assert_reference(child, source: seam.turn, prefix: [settled])
    assert_equal settled.position, child.conversation_ancestries.sole.boundary_position
    assert_includes before.to_json, "run status needs_attention"

    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: seam.agent_run, task_key: "r1", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    assert_equal "running", seam.agent_run.reload.status
    assert_nil @conversation.reload.active_turn_id, "the reopen has not converged yet"
    pending_reopen = fork(side: true)
    assert_reference(pending_reopen, source: seam.turn, prefix: [settled])
    reopening_snapshot = history(pending_reopen)
    assert_includes reopening_snapshot.to_json, "run status running"

    AgentRuns::Transition.agent_run(seam.agent_run, status: "paused", paused_at: Time.current)
    paused = fork(side: true)
    assert_reference(paused, source: seam.turn, prefix: [settled])
    paused_snapshot = history(paused)
    assert_includes paused_snapshot.to_json, "run status paused"
    AgentRuns::Transition.agent_run(seam.agent_run, status: "running", paused_at: nil)

    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal "running", seam.turn.reload.status
    run_round(seam.agent_run, sse_success("repaired"))
    AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal before, history(child), "repair cannot rewrite the side's prefix or held-work reference"
    assert_equal reopening_snapshot, history(pending_reopen), "convergence cannot rewrite the pre-convergence reference"
    assert_equal paused_snapshot, history(paused), "resume cannot rewrite the paused reference"
  end

  test "a held first turn retains its seed and reference before the side boundary" do
    seam = loop_turn
    AgentRuns::Transition.agent_run(seam.agent_run, status: "needs_attention", attention_reason: "halt_failure")
    Conversations::Turns::Converge.call

    child = fork(side: true)

    assert_reference(child, source: seam.turn, prefix: [])
    assert_equal(-1, child.conversation_ancestries.sole.boundary_position)
    assert_equal 1, child.timeline_position_head
    segments = Conversations::ContextAssembly::ChatHistory.call(conversation: child).segments
    assert_equal "answer", segments.first.text
    assert_includes segments[-2].text, "run status needs_attention"
    assert_equal Conversations::ContextAssembly::ChatHistory::BOUNDARY_TEXT, segments.last.text
    assert_equal "user", segments.last.role
  end

  test "a delivered reply remains in the side prefix while its background work finishes" do
    seam = loop_turn
    run_round(seam.agent_run, sse_success("the reply"))
    AgentRuns::Transition.agent_run(seam.agent_run.reload, delivered_at: Time.current)
    Conversations::Turns::Converge.call
    assert_equal "completed", seam.turn.reload.status
    assert_equal "running", seam.agent_run.reload.status

    child = fork(side: true)
    before = history(child)

    assert_equal [seam.turn.id], child.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current)
    assert_equal 0, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal before, history(child)
  end

  private

    def settled_turn
      turn = @conversation.conversation_turns.create!(
        position: @conversation.timeline_position_head, kind: "direct_reply", role: "assistant",
        status: "completed", speaker: @actor, control_owner_user: @human
      )
      variants = ["original", "alternative"].map.with_index do |text, position|
        variant = turn.conversation_turn_variants.create!(position: position, status: "completed", source: "manual")
        ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => text }], seal: true)
        variant
      end
      turn.update!(active_variant: variants.first)
      @conversation.update!(timeline_position_head: turn.position + 1)
      [turn, *variants]
    end

    def fork(turn: nil, side: false)
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: @conversation.reload, turn_public_id: turn&.public_id,
        variant_public_id: nil, acting_user: @human, title: nil, side: side
      ))
      assert_predicate result, :accepted?, result.inspect
      result.value
    end

    def edit(turn, conversation: @conversation)
      Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
        conversation: conversation, turn_public_id: turn.public_id,
        entries: [{ "text" => "changed" }], acting_user: @human
      ))
    end

    def assert_content_frozen(turn, sibling)
      assert_no_difference ["ConversationTurnVariant.count", "AgentRun.count", "ModelInvocation.count"] do
        assert_equal :branch_required, edit(turn).outcome
        activated = Conversations::Variants::Activate.call(Conversations::Variants::Activate::Command.new(
          conversation: @conversation, turn_public_id: turn.public_id,
          variant_public_id: sibling.public_id, acting_user: @human
        ))
        assert_equal :branch_required, activated.outcome
        regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
          conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
          provider_id: "dev", model_ref: "mock-text", reasoning_effort: nil, request_options: nil
        ))
        assert_equal :branch_required, regenerated.outcome
      end
      assert_not turn.reload.update(active_variant: sibling)
      assert turn.errors.added?(:active_variant, :readonly)
    end

    def history(conversation)
      AgentAPI::ConversationPresenter.turn_entries(conversation.timeline.entries(surface: :timeline))
    end

    def assert_reference(child, source:, prefix:)
      reference = child.conversation_turns.sole
      assert_predicate reference, :reference?
      assert_equal source.public_id, reference.forked_from_turn_public_id
      assert_equal source.active_variant.public_id, reference.forked_from_variant_public_id
      assert_equal prefix.map(&:id) + [reference.id], child.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
      assert_nil reference.active_variant.agent_run
      assert_not_predicate reference, :tail?
    end

    def loop_turn
      seam = create_run_backed_turn(conversation: @conversation.reload, acting_user: @human)
      ContentBodies::Replace.call(owner: seam.variant, role: "prompt",
        entries: [{ "text" => "answer" }], readable_text: "answer", seal: true)
      grow!(seam.agent_run, model("r1", "prompt" => "answer"))
      seam
    end

    def run_round(agent_run, response)
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation.agent_run_id == agent_run.id
      end
      assert_not_nil admitted
      clear_enqueued_jobs
      apply_via(admitted.attempt, response)
      AgentRuns::ConvergeTerminalSteps.call
    end
end
