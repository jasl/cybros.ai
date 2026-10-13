require "test_helper"

class Conversations::Turns::RegeneratePromptTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  test "a different model re-asks the first turn's own question" do
    turn = settled_reply

    result = regenerate(turn, model_ref: "mock-priced")

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "the only question", request_text(result.value)
    assert_equal "the only question", result.value.content_bodies.find_by!(role: "prompt").readable_text
  end

  test "a smaller model drops oversized optional history while retaining the original question" do
    old_text = "obsolete context " * 10_000
    post_input!(@conversation, acting_user: @human, text: old_text)
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = settled_reply(model_ref: "mock-windowless")
    assert_includes request_text(turn.active_variant), old_text

    result = regenerate(turn, model_ref: "mock-text")

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "the only question", request_text(result.value),
      "history is optional; the saved question is the separately funded input"
  end

  test "an edited reply still re-asks its own question when no sealed request remains" do
    turn = settled_reply
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id,
      entries: [{ "text" => "the edited answer" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?

    result = regenerate(turn.reload)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "the only question", request_text(result.value)
  end

  test "reassembly keeps the original speaker and sender when another member regenerates" do
    sender = SecureRandom.uuid_v7
    turn = settled_reply(author: users(:curator), origin: "agent", sender: sender)
    expected = Conversations::ContextAssembly::SpeakerEnvelope.for_turn(turn, "the only question")

    result = regenerate(turn, model_ref: "mock-priced")

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal expected, request_text(result.value)
    assert_includes expected, "user=\"#{users(:curator).public_id}\""
    assert_includes expected, "conversation=\"#{sender}\""
  end

  test "a loop-backed first turn re-asks its question on another model" do
    agent = users(:agent)
    declare_tools!(agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: agent, text: "the loop question")
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("the old answer"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status

    result = regenerate(turn, model_ref: "mock-priced")

    assert_predicate result, :accepted?, result.outcome.inspect
    body = result.value.agent_run.agent_run_tasks.find_by!(node_key: "r1").content_bodies.find_by!(role: "input")
    assert_equal "the loop question", body_text(body)
  end

  private

    def settled_reply(author: @human, origin: "person", sender: nil, model_ref: "mock-text")
      input = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: @conversation, acting_user: author, kind: "direct_reply", role: "user",
        entries: [{ "text" => "the only question" }], visible_in_context: true, delivery_mode: "queue",
        context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: model_ref,
        reasoning_effort: nil, request_options: nil, origin: origin, sender_conversation_public_id: sender
      ))
      assert_predicate input, :accepted?, input.outcome.inspect
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.conversation_turns.order(:position).last
      invocation = turn.active_variant.model_invocation
      attempt = ModelInvocations::AdmitQueuedWork.call.admitted.find { |candidate|
        candidate.attempt.model_invocation_id == invocation.id
      }.attempt
      clear_enqueued_jobs
      apply_via(attempt, sse_success("the old answer"))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      turn
    end

    def regenerate(turn, model_ref: nil)
      Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
        provider_id: model_ref ? "dev" : nil, model_ref: model_ref, reasoning_effort: nil, request_options: nil
      ))
    end

    def request_text(variant)
      body_text(variant.model_invocation.content_bodies.find_by!(role: "request"))
    end

    def body_text(body)
      body.content_body_entries.flat_map { |entry| Array(entry.content_fragment.payload["parts"]) }
        .filter_map { |part| part["text"] }.join("\n\n")
    end
end
