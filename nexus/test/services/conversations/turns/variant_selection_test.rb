require "test_helper"

class Conversations::Turns::VariantSelectionTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "selecting a completed answer replaces a held regeneration without reopening its failed loop" do
    turn, original, held = held_regeneration
    boundary = @conversation.conversation_event_items.maximum(:sequence)

    selected, frames = capture_turns do
      activate(turn, original)
    end

    assert_predicate selected, :accepted?
    assert_equal original.id, turn.reload.active_variant_id
    assert_equal "completed", turn.status, "the selected completed answer is the turn's current result"
    assert_equal "failed", held.reload.status
    assert_equal "needs_attention", held.agent_loop.reload.status
    assert_predicate held.agent_loop, :stopped?
    assert_nil @conversation.reload.active_turn_id
    assert_selection_narrated(turn, original, boundary, frames)

    count = @conversation.conversation_event_items.count
    same, frames = capture_turns { activate(turn, original) }
    assert_predicate same, :accepted?
    assert_empty frames, "reselecting the active candidate publishes nothing"
    assert_equal count, @conversation.conversation_event_items.count

    rejected = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: held.agent_loop, task_key: "r1", acting_user: @human
    ))
    assert_equal :not_adjudicable, rejected.outcome
    schedule_loop!(held.agent_loop)
    assert_equal "canceled", held.agent_loop.reload.status
    Conversations::Turns::Converge.call
    assert_equal original.id, turn.reload.active_variant_id
    assert_equal "completed", turn.status

    post_input!(@conversation, acting_user: @human, text: "continue from the selected answer")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    Conversations::Turns::Converge.call
    schedule_loop!(held.agent_loop)
    assert_equal ["canceled", nil], held.agent_loop.reload.values_at(:status, :failure_reason)
    assert_equal original.id, turn.reload.active_variant_id
    assert_equal "completed", turn.status
  end

  test "editing a held answer publishes its completed manual candidate and keeps the old loop overridden" do
    turn, _original, held = held_regeneration
    boundary = @conversation.conversation_event_items.maximum(:sequence)

    edited, frames = capture_turns do
      Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
        conversation: @conversation.reload, turn_public_id: turn.public_id,
        entries: [{ "text" => "my own answer" }], acting_user: @human
      ))
    end

    assert_predicate edited, :accepted?
    assert_equal "completed", turn.reload.status
    assert_selection_narrated(turn, edited.value, boundary, frames)
    assert_equal "my own answer", frames.sole.dig(:turn, :active_variant, :content)
    assert_not frames.sole.key?(:agent_loop_public_id), "the edit is not the old execution"
    rejected = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: held.agent_loop, task_key: "r1", acting_user: @human
    ))
    assert_equal :not_adjudicable, rejected.outcome
    Conversations::Turns::Converge.call
    assert_equal edited.value.id, turn.reload.active_variant_id
    assert_equal "my own answer", turn.active_variant.content_bodies.find_by!(role: "content").effective_text
  end

  private

    def activate(turn, variant)
      Conversations::Variants::Activate.call(Conversations::Variants::Activate::Command.new(
        conversation: @conversation.reload, turn_public_id: turn.public_id,
        variant_public_id: variant.public_id, acting_user: @human
      ))
    end

    def capture_turns
      frames = []
      result = nil
      ActionCable.server.stub(:broadcast, ->(stream, payload) {
        item = payload.fetch(:event) if stream.to_s.end_with?(":transcript")
        frames << item if item&.fetch(:type) == "turn"
      }) { result = yield }
      [result, frames]
    end

    def assert_selection_narrated(turn, variant, boundary, frames)
      items = @conversation.conversation_event_items.where(sequence: (boundary + 1)..).order(:sequence)
      assert_equal %w[turn_variant turn_status], items.map(&:item_type)
      identity = { "turn_public_id" => turn.public_id, "variant_public_id" => variant.public_id }
      identity["agent_loop_public_id"] = variant.agent_loop.public_id if variant.agent_loop
      items.each { |item| assert_equal identity, item.payload.slice(*identity.keys) }
      status = items.last.payload
      assert_equal ["completed", "completed", "direct_reply"],
        status.values_at("status", "variant_status", "turn_kind")
      frame = frames.sole
      assert_equal identity, frame.stringify_keys.slice(*identity.keys)
      assert_equal variant.public_id, frame.dig(:turn, :active_variant, :public_id)
      assert_equal "completed", frame.dig(:turn, :status)
    end

    def held_regeneration
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "the question")
      schedule_loop!(agent_loop)
      run_loop_round!(agent_loop, sse_success("original answer"))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      original = turn.active_variant
      regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
        provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
      ))
      assert_predicate regenerated, :accepted?
      held = regenerated.value
      schedule_loop!(held.agent_loop)
      run_loop_round!(held.agent_loop, json_response(400, { error: { message: "no" } }))
      Conversations::Turns::Converge.call
      assert_equal "failed", turn.reload.status
      assert_equal held.id, turn.active_variant_id
      [turn, original, held]
    end
end
