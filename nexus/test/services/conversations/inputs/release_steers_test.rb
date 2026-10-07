require "test_helper"

# The third steering strand, one body for both hosts: a steer outlives its target and falls back to
# the queue — at a reply's terminal from the converger, at a loop's terminal from the loop's own
# status write — and never at a hold, where the reopened loop still owes it a boundary.
class Conversations::Inputs::ReleaseSteersTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def accept!(kind: "message", text: "hi", host: @conversation, **over)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: host, acting_user: @human, kind: kind,
      role: "user", entries: [{ "text" => text }],
      visible_in_context: true, delivery_mode: "queue", context_mode: nil,
      context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(over)))
    assert_predicate result, :accepted?
    result.value
  end

  def released_items(host)
    host.conversation_event_items.where(item_type: "input_edited")
      .select { |item| item.payload["reason"] == "steer_target_settled" }
  end

  test "a settled target releases its steer back to the queue and frees the bound" do
    accept!(text: "start me")
    accept!(kind: "direct_reply", text: "reply", provider_id: "dev", model_ref: "mock-text")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = @conversation.reload.active_turn
    assert_not_nil turn

    steer = accept!(delivery_mode: "steer", text: "actually, do this")
    assert_equal "steering", steer.state
    assert_equal 1, @conversation.conversation_inputs.caller_authored.count

    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == @conversation.id
    end
    apply_via(admitted.attempt, sse_success("answered"))
    Conversations::Turns::Converge.call

    steer.reload
    assert_equal "pending", steer.state,
      "the binding is over — the words fall back to the queue rather than vanishing"
    assert_nil steer.steering_target_turn_id
    assert_equal 0, @conversation.conversation_inputs.where(state: "steering").count
    assert_equal [steer.public_id], released_items(@conversation).map { |i| i.payload["input_public_id"] }
  end

  test "a canceled turn releases its steer too" do
    accept!(text: "start me")
    accept!(kind: "direct_reply", text: "reply", provider_id: "dev", model_ref: "mock-text")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    steer = accept!(delivery_mode: "steer", text: "redirect")
    assert_equal "steering", steer.state

    result = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: @human
    ))
    assert_predicate result, :accepted?
    Conversations::Turns::Converge.call

    assert_equal "pending", steer.reload.state
  end

  # The loop-side site, on the conversation host: a loop-backed loop's
  # terminal status write releases the steer bound to its turn, narrating
  # on the conversation under the loop lock.
  test "a loop-backed loop's terminal releases the steer bound to its turn, on its conversation" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    steer = accept!(delivery_mode: "steer", text: "redirect")
    assert_equal seam.turn.id, steer.steering_target_turn_id

    AgentRuns::Transition.agent_run(seam.agent_run, status: "canceled",
      completed_at: Time.current)

    steer.reload
    assert_equal "pending", steer.state
    assert_nil steer.steering_target_turn_id
    assert_equal [steer.public_id],
      released_items(@conversation).map { |i| i.payload["input_public_id"] }
    assert_empty seam.agent_run.conversation_event_items, "a loop-backed loop narrates nowhere else"
  end

  test "a standalone loop's terminal releases its own bound steer, on itself" do
    agent_run = AgentRun.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    steer = accept!(host: agent_run, delivery_mode: "steer", text: "redirect",
      visible_in_context: nil)
    assert_equal "steering", steer.state
    assert_nil steer.steering_target_turn_id, "a one-turn host binds to itself"

    AgentRuns::Transition.agent_run(agent_run, status: "completed", completed_at: Time.current)

    assert_equal "pending", steer.reload.state
    assert_equal [steer.public_id], released_items(agent_run).map { |i| i.payload["input_public_id"] }
  end

  # The release is one set write over the rows it was handed, whatever
  # their number; the narration reads the rows it loaded.
  test "a release writes its steers back to the queue in one statement" do
    agent_run = AgentRun.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    steers = 3.times.map do |index|
      accept!(host: agent_run, delivery_mode: "steer", text: "redirect #{index}", visible_in_context: nil)
    end
    assert_equal %w[steering steering steering], steers.map(&:state)

    assert_queries_match(/UPDATE "conversation_inputs"/, count: 1) do
      assert_equal 3, Conversations::Inputs::ReleaseSteers.call(host: agent_run, inputs: agent_run.conversation_inputs)
    end
    versions = steers.map(&:lock_version)
    assert_equal %w[pending pending pending], steers.map { |steer| steer.reload.state }
    assert_equal versions.map(&:succ), steers.map(&:lock_version),
      "the row changed, so the version a reader holds for the edit door's CAS is stale"
    assert_equal steers.map(&:public_id).sort, released_items(agent_run).map { |i| i.payload["input_public_id"] }.sort
  end

  # The `replaced` gap: a stop writes `canceling`, which is not terminal; the release lands one
  # drain pass later at `canceled`.
  test "a stopping loop keeps its steer bound until the drain lands canceled" do
    agent_run = AgentRun.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    steer = accept!(host: agent_run, delivery_mode: "steer", text: "redirect",
      visible_in_context: nil)

    AgentRuns::Transition.agent_run(agent_run, status: "canceling", canceling_since: Time.current)
    assert_equal "steering", steer.reload.state, "canceling is a gap of one drain pass"
    assert_equal :run_settled, loop_input!(agent_run, acting_user: @human, text: "more").outcome,
      "and the door refuses a new binding meanwhile"

    AgentRuns::EvaluateQuiescence.call(agent_run)
    assert_equal "canceled", agent_run.reload.status
    assert_equal "pending", steer.reload.state
  end

  test "a hold releases nothing: the steer stays bound for the reopened loop" do
    agent_run = AgentRun.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    steer = accept!(host: agent_run, delivery_mode: "steer", text: "redirect",
      visible_in_context: nil)

    AgentRuns::Transition.agent_run(agent_run, status: "needs_attention",
      attention_reason: "halt_failure")

    assert_equal "steering", steer.reload.state
    assert_empty released_items(agent_run)
  end
end
