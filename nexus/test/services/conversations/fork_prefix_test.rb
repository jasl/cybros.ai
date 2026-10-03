require "test_helper"

class Conversations::ForkPrefixTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @actor = Actors::Resolve.member(account: @account, user: @human)
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

  test "a side skips a held loop's tail while retry and convergence continue to change its rounds" do
    settled, = settled_turn
    seam = loop_turn
    run_round(seam.agent_loop, json_response(400, { "error" => "bad" }))
    AgentLoops::ScheduleReady.call(agent_loop_id: seam.agent_loop.id)
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", seam.agent_loop.reload.status
    assert_equal "failed", seam.turn.reload.status
    assert_nil @conversation.reload.active_turn_id

    child = fork(side: true)
    before = history(child)
    assert_equal [settled.id], child.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
    assert_equal settled.position, child.conversation_ancestries.sole.boundary_position

    retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: seam.agent_loop, task_key: "r1", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    assert_equal "running", seam.agent_loop.reload.status
    assert_nil @conversation.reload.active_turn_id, "the reopen has not converged yet"
    pending_reopen = fork(side: true)
    assert_equal [settled.id], pending_reopen.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }

    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "paused", paused_at: Time.current)
    paused = fork(side: true)
    assert_equal [settled.id], paused.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "running", paused_at: nil)

    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal "running", seam.turn.reload.status
    run_round(seam.agent_loop, sse_success("repaired"))
    AgentLoops::ScheduleReady.call(agent_loop_id: seam.agent_loop.id)
    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal "completed", seam.turn.reload.status
    assert_equal before, history(child), "repair cannot rewrite the side's inherited prefix"
  end

  test "a held first turn yields an empty side prefix" do
    seam = loop_turn
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "needs_attention", attention_reason: "halt_failure")
    Conversations::Turns::Converge.call

    child = fork(side: true)

    assert_empty child.timeline.entries(surface: :timeline)
    assert_equal(-1, child.conversation_ancestries.sole.boundary_position)
    assert_equal 0, child.timeline_position_head
  end

  test "a delivered reply remains in the side prefix while its background work finishes" do
    seam = loop_turn
    run_round(seam.agent_loop, sse_success("the reply"))
    AgentLoops::Transition.agent_loop(seam.agent_loop.reload, delivered_at: Time.current)
    Conversations::Turns::Converge.call
    assert_equal "completed", seam.turn.reload.status
    assert_equal "running", seam.agent_loop.reload.status

    child = fork(side: true)
    before = history(child)

    assert_equal [seam.turn.id], child.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "completed", completed_at: Time.current)
    assert_equal 0, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal before, history(child)
  end

  private

    def settled_turn
      turn = @conversation.conversation_turns.create!(
        position: @conversation.timeline_position_head, kind: "direct_reply", role: "assistant",
        status: "completed", speaker_actor: @actor, control_owner_user: @human
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
      assert_no_difference ["ConversationTurnVariant.count", "AgentLoop.count", "ModelInvocation.count"] do
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

    def loop_turn
      seam = create_loop_backed_turn(conversation: @conversation.reload, acting_user: @human)
      grow!(seam.agent_loop, model("r1", "prompt" => "answer"))
      seam
    end

    def run_round(agent_loop, response)
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation.agent_loop_id == agent_loop.id
      end
      assert_not_nil admitted
      clear_enqueued_jobs
      apply_via(admitted.attempt, response)
      AgentLoops::ConvergeTerminalSteps.call
    end
end
