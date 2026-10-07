require "test_helper"
require "test_helpers/conversation_api_test_helper"
require "test_helpers/lock_order_test_helper"

class AgentAPI::V1::ConversationRunReplayTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include LockOrderTestHelper

  {
    "provider_http_error" => "invalid reasoning item",
  }.each do |reason, message|
    test "a loop #{reason} downgrades later default assembly but preserves explicit replay" do
      conversation = conversation_with_reasoning
      turn, agent_run, invocation = begin_reply(conversation, "Second question")
      original = read_request(conversation, turn)
      assert_native_reasoning original
      refuse(agent_run, message)
      assert_equal reason, invocation.reload.failure_reason_key

      sequences = assert_ladder_order("hosted native reasoning refusal") do
        assert_equal 1, AgentRuns::ConvergeTerminalSteps.call(invocation_id: invocation.id)[:recorded]
      end
      seen = sequences.flatten
      assert_operator seen.index("conversations"), :<, seen.index("agent_runs")
      assert_operator seen.index("agent_runs"), :<, seen.index("model_invocations")
      assert_not_nil conversation.reload.reasoning_replay_downgraded_at,
        "the step result changes the default without waiting for turn settlement"
      assert_equal turn.public_id, downgrade_events(conversation).sole.dig("payload", "turn_public_id")
      assert_equal original, read_request(conversation, turn), "the refused request stays sealed"
      settle_turn(conversation, agent_run)

      later, later_loop, = begin_reply(conversation, "Third question")
      assert_no_native_reasoning read_request(conversation, later)
      complete_reply(conversation, later_loop, reasoning: "fresh plan", encrypted: "fresh-blob")

      explicit, explicit_loop, explicit_invocation = begin_reply(conversation, "Fourth question",
        reasoning_replay: { mode: "last_turn" })
      assert_native_reasoning read_request(conversation, explicit)
      refuse(explicit_loop, message)
      stamp = conversation.reload.reasoning_replay_downgraded_at
      assert_equal 1, AgentRuns::ConvergeTerminalSteps.call(invocation_id: explicit_invocation.id)[:recorded]
      assert_equal 0, AgentRuns::ConvergeTerminalSteps.call(invocation_id: explicit_invocation.id)[:recorded]
      assert_equal stamp, conversation.reload.reasoning_replay_downgraded_at
      assert_equal 1, downgrade_events(conversation).length, "the downgrade is once per conversation"
    end
  end

  # A window overflow is compaction's, never a trace cut: the repair runs and the stamp stays unset,
  # so the loop keeps replaying its turn's thinking (a tool turn must pass it back) and later seeds
  # keep the default.
  test "an overflow repair compacts and never records the downgrade" do
    conversation = conversation_with_reasoning(compaction_policy: { "mode" => "kernel" })
    turn, agent_run, = begin_reply(conversation, "Second question")
    run_loop_round!(agent_run, sse_success("Read the file", reasoning: "Choose a file", reasoning_encrypted: "read-blob",
      tool_calls: [{ id: "call_read", name: "read_file", arguments: '{"path":"README.md"}' }]))
    result = AgentRuns::Parks::Settle.call(
      node: agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read"), trusted: true,
      content: "File contents"
    )
    assert_predicate result, :applied?
    schedule_loop!(agent_run)
    node = agent_run.agent_run_tasks.find_by!(node_key: "r2")
    invocation = node.selected_model_invocation
    assert_native_reasoning("entries" => sealed_request_entries(invocation))
    refuse(agent_run, "prompt is too long: 213462 tokens > 200000 maximum")
    assert_equal "provider_context_overflow", invocation.reload.failure_reason_key

    assert_ladder_order("hosted native reasoning overflow repair") do
      assert_equal 1, AgentRuns::ConvergeTerminalSteps.call(invocation_id: invocation.id)[:recorded]
    end
    assert_predicate node.reload, :repaired?, "the fixture must enter automatic compaction"
    assert_equal "queued", node.status
    assert_equal "running", turn.reload.status
    assert_nil conversation.reload.reasoning_replay_downgraded_at
    assert_empty downgrade_events(conversation)
  end

  test "retry retains its sealed replay after the conversation default is downgraded" do
    conversation = conversation_with_reasoning
    turn, agent_run, invocation = begin_reply(conversation, "Second question")
    original = read_request(conversation, turn)
    refuse(agent_run, "invalid reasoning item")
    AgentRuns::ConvergeTerminalSteps.call(invocation_id: invocation.id)
    settle_turn(conversation, agent_run)
    assert_not_nil conversation.reload.reasoning_replay_downgraded_at

    node = agent_run.agent_run_tasks.find_by!(selected_model_invocation_id: invocation.id)
    post "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{agent_run.public_id}/tasks/#{node.node_key}/retry",
      headers: auth
    assert_response :success
    Current.reset
    schedule_loop!(agent_run)
    retried = node.reload.selected_model_invocation
    assert_not_equal invocation.id, retried.id
    assert_equal original.fetch("entries"), sealed_request_entries(retried)
    assert_native_reasoning read_request(conversation, turn)
  end

  test "downgrade event and step terminal marker roll back together" do
    conversation = conversation_with_reasoning
    turn, agent_run, invocation = begin_reply(conversation, "Second question")
    refuse(agent_run, "invalid reasoning item")

    ApplicationRecord.transaction(requires_new: true) do
      assert_equal 1, AgentRuns::ConvergeTerminalSteps.call(invocation_id: invocation.id)[:recorded]
      assert_not_nil conversation.reload.reasoning_replay_downgraded_at
      assert_not_nil invocation.reload.terminal_event_recorded_at
      assert_equal 1, downgrade_events(conversation).length
      raise ActiveRecord::Rollback
    end

    assert_nil conversation.reload.reasoning_replay_downgraded_at
    assert_nil invocation.reload.terminal_event_recorded_at
    assert_empty downgrade_events(conversation)
    assert_equal 1, AgentRuns::ConvergeTerminalSteps.call[:recorded], "the recurring floor recovers the same row"
    assert_equal turn.public_id, downgrade_events(conversation).sole.dig("payload", "turn_public_id")
  end

  test "successful native replay and refused ordinary text do not lock the conversation" do
    conversation = conversation_with_reasoning
    turn, agent_run, invocation = begin_reply(conversation, "Second question")
    assert_native_reasoning read_request(conversation, turn)
    apply_via(loop_attempt(agent_run), sse_success("A reply."))
    sequences = assert_ladder_order("successful native replay") do
      assert_equal 1, AgentRuns::ConvergeTerminalSteps.call(invocation_id: invocation.id)[:recorded]
    end
    assert_not_includes sequences.flatten, "conversations"
    settle_turn(conversation, agent_run)

    ordinary, ordinary_loop, ordinary_invocation = begin_reply(conversation, "No replay",
      reasoning_replay: { mode: "none" })
    assert_no_native_reasoning read_request(conversation, ordinary)
    refuse(ordinary_loop, "request refused")
    sequences = assert_ladder_order("refused ordinary text") do
      assert_equal 1, AgentRuns::ConvergeTerminalSteps.call(invocation_id: ordinary_invocation.id)[:recorded]
    end
    assert_not_includes sequences.flatten, "conversations"
    assert_nil conversation.reload.reasoning_replay_downgraded_at
    assert_empty downgrade_events(conversation)
  end

  private

    def conversation_with_reasoning(compaction_policy: { "mode" => "off" })
      declare_tools!(users(:agent), compaction_policy: compaction_policy)
      post conversations_path, headers: auth(SecureRandom.uuid), as: :json,
        params: { conversation: { title: "Loop replay", answering_user_public_id: users(:agent).public_id } }
      assert_response :created
      conversation = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
      _, agent_run, = begin_reply(conversation, "First question")
      complete_reply(conversation, agent_run, reasoning: "The plan", encrypted: "original-blob")
      conversation
    end

    def begin_reply(conversation, text, reasoning_replay: nil)
      clear_enqueued_jobs
      post conversation_inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { kind: "direct_reply", text: text, model: { model: "dev/mock-text" },
                           reasoning_replay: reasoning_replay }.compact }
      assert_response :accepted
      Current.reset
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
      turn = conversation.conversation_turns.order(:position).last
      agent_run = turn.active_variant.agent_run
      assert_not_nil agent_run
      schedule_loop!(agent_run)
      [turn, agent_run, agent_run.model_invocations.sole]
    end

    def complete_reply(conversation, agent_run, reasoning: nil, encrypted: nil)
      run_loop_round!(agent_run, sse_success("A reply.", reasoning: reasoning, reasoning_encrypted: encrypted))
      settle_turn(conversation, agent_run)
    end

    def settle_turn(conversation, agent_run)
      schedule_loop!(agent_run)
      Conversations::Turns::Converge.call(conversation_id: conversation.id, agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    def refuse(agent_run, message)
      apply_via(loop_attempt(agent_run), json_response(400, { "error" => { "message" => message } }))
    end

    def read_request(conversation, turn)
      get request_path(conversation, turn, turn.active_variant), headers: auth
      assert_response :success
      response.parsed_body.fetch("request")
    end

    def assert_native_reasoning(request)
      assert request.fetch("entries").any? { |entry| entry["type"] == "reasoning_item" }
    end

    def assert_no_native_reasoning(request)
      assert_not request.fetch("entries").any? { |entry| entry["type"] == "reasoning_item" }
    end

    def downgrade_events(conversation)
      get conversation_events_path(conversation), headers: auth
      assert_response :success
      response.parsed_body.fetch("events").select { |event| event.fetch("type") == "reasoning_replay_downgraded" }
    end
end
