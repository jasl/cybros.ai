require "test_helper"

class ModelInvocations::ProviderStartSourceStopTest < ActiveJob::TestCase
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a committed loop stop refuses a prepared provider start before cancellation drains" do
    agent_loop, attempt = prepared_loop
    AgentLoops::Stop.mark_now(agent_loop)

    assert_equal "running", agent_loop.reload.status
    assert_equal "running", attempt.model_invocation.reload.status
    assert_refused_start(attempt)
  end

  test "a stopped ancestor refuses a derived loop provider start before recovery reaches it" do
    source, variant = derived_reply(tools: [READ_TOOL])
    derived = variant.agent_loop
    schedule_loop!(derived)
    attempt = loop_attempt(derived)

    AgentLoops::Stop.mark_now(source)
    assert_not_predicate derived.reload, :stopped?
    assert_equal "running", derived.status
    assert_refused_start(attempt)
  end

  test "a stopped ancestor also refuses a tool-less sent request provider start" do
    source, variant = derived_reply(tools: [])
    invocation = variant.model_invocation
    assert invocation, "a tool-less reply has its existing direct invocation owner"
    attempt = ModelInvocations::AdmitQueuedWork.call.admitted.find { |candidate|
      candidate.attempt.model_invocation_id == invocation.id
    }.attempt
    clear_enqueued_jobs

    AgentLoops::Stop.mark_now(source)
    assert_equal "running", invocation.reload.status
    assert_refused_start(attempt)
  end

  test "a graceful self stop keeps its already dispatched conversation invocation startable" do
    _source, variant = derived_reply(tools: [READ_TOOL])
    derived = variant.agent_loop
    schedule_loop!(derived)
    attempt = loop_attempt(derived)
    assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
      agent_loop: derived, acting_user: @human, force: false)), :accepted?
    schedule_loop!(derived)
    assert_equal "canceling", derived.reload.status

    assert_predicate start(attempt), :started?
    assert_predicate attempt.reload, :started?
  end

  test "a later source cut preserves an already started provider attempt" do
    agent_loop, attempt = prepared_loop
    assert_predicate start(attempt), :started?
    started_at = attempt.reload.provider_started_at
    AgentLoops::Stop.mark_now(agent_loop)

    result = start(attempt)
    assert_equal ModelInvocations::ProviderStart::ALREADY_STARTED, result.outcome
    assert_nil result.context
    assert_equal started_at, attempt.reload.provider_started_at
    assert_equal "running", attempt.status, "already sent work uses the existing cancellation drain"
  end

  private

    def prepared_loop
      agent_loop = seed(model("round"))
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human)), :accepted?
      schedule_loop!(agent_loop)
      [agent_loop, loop_attempt(agent_loop)]
    end

    def derived_reply(tools:)
      declare_tools!(@agent, tools: tools)
      host = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      source = create_loop_backed_turn(conversation: host, acting_user: @human,
        turn_status: "completed", variant_status: "completed", loop_status: "completed").agent_loop
      source.update!(delivered_at: Time.current, completed_at: Time.current)
      host.update!(active_turn: nil)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
        host: host, acting_user: @human, entries: [{ "text" => "background result" }],
        sender_conversation_public_id: host.public_id,
        agent_loop_public_id: source.public_id, task_key: "background", kind: "direct_reply",
        provider_id: "dev", model_ref: "mock-text"))
      assert_predicate result, :accepted?
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: host.id)
      assert_predicate applied, :accepted?
      [source, applied.value.active_variant]
    end

    def assert_refused_start(attempt)
      result = start(attempt)
      assert_equal ModelInvocations::ProviderStart::AUTHORITY_LOST, result.outcome
      assert_nil result.context
      assert_equal "prepared", attempt.reload.status
      assert_nil attempt.provider_started_at
    end

    def start(attempt)
      invocation = attempt.model_invocation
      ModelInvocations::ProviderStart.call(attempt: attempt, host: "model_runner",
        base_url: ModelCatalog.provider_base_url(invocation.provider_id),
        profile: DevModelLane.profile_for_invocation(invocation))
    end
end
