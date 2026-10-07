require "test_helper"

class Conversations::Turns::ConvergeTargetTest < ActiveJob::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  test "a precise wake settles only its loop despite another retained failure" do
    retained = held_reply
    target = held_reply
    settle = Conversations::TranscriptStream.method(:settled_turn)
    attempts = []
    failing = ->(turn, **keys) do
      attempts << turn.id
      raise IOError, "transcript unavailable" if turn.id == retained.turn.id

      settle.call(turn, **keys)
    end
    result = nil

    Rails.error.stub(:report, ->(*) { }) do
      Conversations::TranscriptStream.stub(:settled_turn, failing) do
        result = converge(target)
      end
    end

    assert_predicate result, :accepted?
    assert_equal 1, result.value[:scanned]
    assert_equal 1, result.value[:recorded]
    assert_not result.value.more?, "a precise wake never starts a global recovery chain"
    assert_equal [target.turn.id], attempts
    assert_equal "failed", target.turn.reload.status
    assert_equal "running", retained.turn.reload.status
  end

  test "a precise wake whose loop or conversation vanished is harmless" do
    target = held_reply
    [
      { conversation_id: target.turn.conversation_id, agent_run_id: 0 },
      { conversation_id: 0, agent_run_id: target.agent_run.id },
    ].each do |address|
      result = Conversations::Turns::Converge.call(**address)

      assert_predicate result, :accepted?
      assert_equal 0, result.value[:recorded]
      assert_not result.value.more?
    end

    assert_equal "running", target.turn.reload.status
    assert_equal "running", target.variant.reload.status
  end

  test "a precise wake rechecks the pair after acquiring its locks" do
    target = held_reply
    lock = AgentRun.method(:lock)
    advanced = false
    advancing = lambda do
      target.agent_run.with_lock do
        AgentRuns::Transition.agent_run(target.agent_run, status: "running", attention_reason: nil)
      end
      advanced = true
      lock.call
    end
    result = nil

    AgentRun.stub(:lock, advancing) { result = converge(target) }

    assert advanced, "the loop advanced after the wake began but before its locked read"
    assert_equal 0, result.value[:recorded]
    assert_not result.value.more?
    assert_equal "running", target.agent_run.reload.status
    assert_equal "running", target.turn.reload.status
    assert_equal "running", target.variant.reload.status
  end

  test "a delayed precise wake chooses the current reopen transition" do
    target = held_reply
    assert_equal 1, converge(target).value[:recorded]
    assert_equal "failed", target.turn.reload.status
    AgentRuns::Transition.agent_run(target.agent_run, status: "running", attention_reason: nil)

    result = converge(target)

    assert_equal 1, result.value[:recorded]
    assert_not result.value.more?
    assert_equal "running", target.turn.reload.status
    assert_equal "running", target.variant.reload.status
    assert_equal target.turn.id, target.turn.conversation.reload.active_turn_id
  end

  private

    def held_reply
      conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
      seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
      AgentRuns::Transition.agent_run(seam.agent_run,
        status: "needs_attention", attention_reason: "halt_failure")
      seam
    end

    def converge(seam)
      Conversations::Turns::Converge.call(
        conversation_id: seam.turn.conversation_id, agent_run_id: seam.agent_run.id
      )
    end
end
