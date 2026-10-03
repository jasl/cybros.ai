require "test_helper"

# THE ADDRESSEE'S ENGINE: a row addressed AWAY from the host's default answerer — a group turn — and
# every row a peer SENT run on the engine that answers for that addressee, in ONE order: the
# addressee's OWN `default_model` (the profile fact its application declared), else its last reply
# turn's model trio in this conversation, else the conversation's last reply turn's, else the row's
# own (the submitted model; the initiator's on a `send` or a brief). The host's own rows posted as
# itself and the kernel's mail keep the trio they carry: every 1:1 lane and every receipt is
# untouched.
class Conversations::AnswerEngineTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @peer = create_agent_member(display_name: "Peer")
    @conversation.conversation_access_entries.create!(user: @peer, level: "full")
    declare_tools!(@agent, tools: [READ_TOOL])
    declare_tools!(@peer, tools: [READ_TOOL])
  end

  def trio(row) = [row.provider_id, row.model_ref, row.reasoning_effort]

  def post!(to: nil, model_ref: "mock-text", by: @human, reasoning_effort: nil)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: by, kind: "direct_reply", role: "user",
      entries: [{ "text" => "go" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: model_ref,
      reasoning_effort: reasoning_effort, request_options: nil,
      answering_user_public_id: (to && "@#{to.handle}")
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    result.value
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

  # The head drained and its turn settled, whichever engine: a loop runs
  # one round, a plain reply one invocation.
  def settle!
    assert_equal 1, drain!
    turn = @conversation.conversation_turns.order(:position).last
    variant = turn.active_variant
    if variant.source == "agent_loop"
      schedule_loop!(variant.agent_loop)
      run_loop_round!(variant.agent_loop, sse_success("done"))
    else
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      apply_via(ModelInvocationAttempt.where(model_invocation_id: variant.model_invocation_id).order(:id).last,
        sse_success("done"))
    end
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    turn
  end

  test "the order: the addressee's last turn here, else the conversation's last, else the row's own" do
    first = post!(to: @peer, model_ref: "mock-text")
    assert_equal %w[dev mock-text], trio(first).first(2), "no reply turn yet: the row's own"
    assert_equal @peer, settle!.answering_user

    second = post!(to: @agent, model_ref: "mock-unmetered")
    assert_equal %w[dev mock-text], trio(second).first(2),
      "A has not answered here: the conversation's last reply turn's trio (B's), not the submitted one"
    assert_equal @agent, settle!.answering_user

    own = post!(model_ref: "mock-unmetered")
    assert_equal %w[dev mock-unmetered], trio(own).first(2), "the default answerer's own row keeps its own"
    assert_equal @human, settle!.answering_user

    third = post!(to: @peer, model_ref: "mock-windowless")
    assert_equal %w[dev mock-text], trio(third).first(2),
      "B's last turn here (mock-text) beats the conversation's last (mock-unmetered) beats the row's (mock-windowless)"
  end

  # STEP 0: the addressee's own preset beats its history here and the row's words; an addressee
  # without one falls through the old rungs.
  test "the addressee's own default_model is step 0: it beats its last turn here and the row's own" do
    declare_tools!(@peer, tools: [READ_TOOL], default_model: "dev/mock-text-only")

    first = post!(to: @peer, model_ref: "mock-text")
    assert_equal ["dev", "mock-text-only", nil], trio(first), "B's preset, at the model's own reasoning default"
    assert_equal @peer, settle!.answering_user

    second = post!(to: @peer, model_ref: "mock-windowless", reasoning_effort: "low")
    assert_equal ["dev", "mock-text-only", nil], trio(second), "B's preset beats B's last turn and the row's words"

    third = post!(to: @agent, model_ref: "mock-windowless")
    assert_equal %w[dev mock-text-only], trio(third).first(2),
      "A has no preset and never answered here: the conversation's last reply turn's (B's), the second rung"
    assert_equal Conversations::AnswerEngine::Trio.new(provider_id: "dev", model_ref: "mock-text-only", reasoning_effort: nil),
      Conversations::AnswerEngine.trio(@conversation, addressee: @peer)
  end

  # The host's own rows posted AS the host keep their words even when the
  # answerer declared a preset — the person chose (「或者要用户自己选」); a
  # peer's SENT row to that same answerer takes the preset: the initiator's
  # words are the last rung, read only when the addressee has nothing.
  test "the answerer's own lane keeps the row's model; a sent row to it takes the answerer's preset" do
    declare_tools!(@agent, tools: [READ_TOOL], default_model: "dev/mock-text-only")
    own = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    own.conversation_access_entries.create!(user: @peer, level: "full")

    person = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: own, acting_user: @human, kind: "direct_reply", role: "user",
      entries: [{ "text" => "go" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate person, :accepted?
    assert_equal %w[dev mock-text], trio(person.value).first(2), "the person's own choice on A's 1:1 lane"

    sent = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: own, acting_user: @peer, kind: "direct_reply", entries: [{ "text" => "from B" }],
      sender_conversation_public_id: @conversation.public_id,
      provider_id: "dev", model_ref: "mock-windowless", reasoning_effort: "low"
    ))
    assert_predicate sent, :accepted?, sent.outcome.to_s
    assert_equal ["dev", "mock-text-only", nil], trio(sent.value),
      "B's send to A's own conversation: A's preset first, B's model (the initiator's) only when A has nothing"
  end

  test "the kernel's mail keeps the surface its loop ran under, whatever the addressee answered on since" do
    post!(to: @agent, model_ref: "mock-text")
    settle!

    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: @human, kind: "direct_reply", entries: [{ "text" => "<task_result />" }],
      origin: ConversationInput::TASK_RESULT_ORIGIN, sender_conversation_public_id: @conversation.public_id,
      answering_user_public_id: @agent.public_id, provider_id: "dev", model_ref: "mock-windowless"
    ))
    assert_predicate result, :accepted?
    assert_equal %w[dev mock-windowless], trio(result.value).first(2)
  end

  test "the resolver reads only reply turns with a model: a message turn and a summary are not engines" do
    post_input!(@conversation, acting_user: @human, text: "a message")
    drain!
    assert_nil Conversations::AnswerEngine.trio(@conversation, addressee: @peer), "nothing has answered"

    post!(to: @peer, model_ref: "mock-text")
    settle!
    post_input!(@conversation, acting_user: @human, text: "another message")
    drain!
    assert_equal %w[dev mock-text],
      Conversations::AnswerEngine.trio(@conversation, addressee: @peer).to_h.values_at(:provider_id, :model_ref)
    assert_equal %w[dev mock-text],
      Conversations::AnswerEngine.trio(@conversation, addressee: @agent).to_h.values_at(:provider_id, :model_ref),
      "A never answered: the conversation's last reply turn's"
  end
end
