require "test_helper"

# THE SINK CHOOSER, which is ONE SITE because both hosts call it: every hosted plane — a loop step,
# whichever host its loop has, and a direct reply — streams through the ONE hosted sink, which
# resolves the host itself, WHICHEVER host executes. The loop step FIRST matters: a loop step's
# invocation carries `agent_loop_id` and no `conversation_id`, and the old loop-first arm sent a
# loop-backed round to an address no channel serves.
#
# The OneShot's narration is the other kind — durable items under the
# one_shot lock — and it stays the reactor's: the queue pair is that plane's
# honestly degraded fallback, and `one_shot_hosts_test` pins the absence.
class ModelInvocations::StreamSinkTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a OneShot gets the durable sink on the reactor host and none on the queue's" do
    one_shot = admitted_attempt

    assert_kind_of OneShotEvents::StreamSink, sink_for(one_shot)
    assert_nil sink_for(one_shot, host: ModelInvocations::RunJob::HOST),
      "the queue pair is this plane's degraded fallback, and that is the difference"
  end

  test "every hosted plane gets the one streaming sink on either host" do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
      answering_user: users(:agent))
    declare_tools!(users(:agent))
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: users(:agent))
    schedule_loop!(agent_loop)
    round = loop_attempt(agent_loop)
    assert_kind_of ConversationEvents::StreamSink, sink_for(round)
    assert_kind_of ConversationEvents::StreamSink,
      sink_for(round, host: ModelInvocations::RunJob::HOST)

    reply = Conversation.create!(workspace: workspaces(:shared), creating_user: @human)
    post_input!(reply, acting_user: @human, kind: "direct_reply", text: "hi",
      provider_id: "dev", model_ref: "mock-text")
    Conversations::Inputs::ApplyNext.drain(conversation_id: reply.id)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == reply.id
    end
    assert_kind_of ConversationEvents::StreamSink, sink_for(admitted.attempt)
    # THE DEFECT, AT THE SITE: a reply the queue worker claimed built no
    # sink at all, so what a person saw depended on a race between hosts.
    assert_kind_of ConversationEvents::StreamSink,
      sink_for(admitted.attempt, host: ModelInvocations::RunJob::HOST)
  end

  private

    def sink_for(attempt, host: ModelRunner::Host::HOST)
      ModelInvocations::StreamSink.for(attempt: attempt, host: host)
    end
end
