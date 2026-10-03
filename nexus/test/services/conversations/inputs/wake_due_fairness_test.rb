require "test_helper"

class Conversations::Inputs::WakeDueFairnessTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    @workspace = workspaces(:shared)
    @user = users(:member)
  end

  test "an older due input behind a paused turn cannot starve recovery in an idle room" do
    busy = Conversation.create!(workspace: @workspace, creating_user: @user)
    idle = Conversation.create!(workspace: @workspace, creating_user: @user)
    seam = create_loop_backed_turn(conversation: busy, acting_user: @user)
    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: seam.agent_loop, acting_user: @user
    )), :accepted?
    older = accept(busy, at: 1.minute.ago)
    later = accept(idle, at: 30.seconds.ago)
    clear_enqueued_jobs # The recurring floor must recover a lost precise wake.

    stub_const(Conversations::Inputs::WakeDue, :BUDGET, 1) do
      3.times do
        perform_enqueued_jobs(only: [Conversations::Inputs::DrainJob, Conversations::Inputs::WakeDueJob]) do
          Conversations::Inputs::WakeDueJob.perform_now
        end
      end
    end

    assert_predicate seam.agent_loop.reload, :paused?
    assert ConversationInput.exists?(older.id), "the paused room's own queue stays pending"
    missed = ConversationInput.exists?(later.id)
    Conversations::Inputs::DrainJob.perform_now(idle.id)
    assert_not ConversationInput.exists?(later.id), "the later room is independently drainable"
    assert_not missed, "repeated recovery passes must reach the idle room beyond retained candidates"
  end

  private

    def accept(conversation, at:)
      outcome = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: @user, kind: "message", role: "user", entries: [{ "text" => "scheduled" }],
        visible_in_context: true, delivery_mode: "queue", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil, deliver_at: at
      ))
      assert_predicate outcome, :accepted?
      outcome.value
    end
end
