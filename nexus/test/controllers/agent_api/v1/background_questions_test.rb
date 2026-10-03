require "test_helper"

class AgentAPI::V1::BackgroundQuestionsTest < ActionDispatch::IntegrationTest
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @token = create_access_token_fixture(user: @human, name: "Member")
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::ASK, Nexus::Compose::DEFINITION])
  end

  test "a detached task can ask while its parent replies and remains answerable during the next turn" do
    turn, agent_loop = open_turn
    call_round(agent_loop, "r1", "task", prompt: "Investigate a target")
    branch = running_branch(agent_loop)
    call_round(agent_loop, branch.node_key, "ask", prompt: "Which target?")

    finish_and_answer(turn, agent_loop)
    continuation = running_branch(agent_loop)
    assert_includes round_request_entries(continuation).to_json, "staging"
    finish_round(agent_loop, continuation.node_key, "Investigation done")
    assert_equal "completed", agent_loop.reload.status

    2.times { AgentLoops::Mail.call(agent_loop) }
    mail = @conversation.conversation_inputs.where(origin: "task_result").sole
    assert_includes mail.text, "Investigation done"
    assert_equal "pending", mail.state, "the next turn runs before background mail drains"
    assert_equal "completed", turn.reload.status
  end

  test "a detached composition announces its question without withholding the foreground reply" do
    turn, agent_loop = open_turn
    call_round(agent_loop, "r1", "compose", script: 'g.ask({ prompt: "Which target?" });')

    finish_and_answer(turn, agent_loop)
    assert_equal "completed", agent_loop.reload.status
    2.times { AgentLoops::Mail.call(agent_loop) }
    mail = @conversation.conversation_inputs.where(origin: "task_result").sole
    assert_includes mail.text, "staging"
  end

  private

    def open_turn
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(agent_loop)
      [turn, agent_loop]
    end

    def running_branch(agent_loop)
      agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name,
        detached: true, status: "running").sole
    end

    def attempt_for(agent_loop, key)
      invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round(agent_loop, key, name, **arguments)
      apply_via(attempt_for(agent_loop, key), sse_success("delegating", tool_calls: [
        { id: "call_#{name}", name: name, arguments: arguments.to_json },
      ]))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::AskJob,
        AgentLoops::ComposeJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end
    end

    def finish_round(agent_loop, key, text)
      apply_via(attempt_for(agent_loop, key), sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def finish_and_answer(turn, agent_loop)
      question = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::AwaitTask.sti_name).sole
      assert_predicate question, :detached?
      finish_round(agent_loop, "r2", "The independent answer is ready")
      assert_predicate agent_loop.reload, :delivered?
      assert_equal "awaiting_human", agent_loop.attention_reason
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status

      next_turn, = open_turn
      assert_equal next_turn.id, @conversation.reload.active_turn_id
      path = "/agent_api/v1/workspaces/#{@workspace.public_id}/agent_loops/#{agent_loop.public_id}"
      get path, headers: { "Authorization" => "Bearer #{@token.secret}" }
      assert_response :success
      assert_equal [question.node_key], response.parsed_body.dig("agent_loop", "attention", "blocked_task_keys")
      get "#{path}/tasks/#{question.node_key}", headers: { "Authorization" => "Bearer #{@token.secret}" }
      assert_response :success
      assert_equal "Which target?", response.parsed_body.dig("task", "prompt")
      post "#{path}/tasks/#{question.node_key}/resolution", as: :json,
        headers: { "Authorization" => "Bearer #{@token.secret}" }, params: { content: "staging" }
      assert_response :success
      assert_equal "completed", question.reload.status
      schedule_loop!(agent_loop)
      assert_nil agent_loop.reload.attention_reason
      assert_equal next_turn.id, @conversation.reload.active_turn_id
    end
end
