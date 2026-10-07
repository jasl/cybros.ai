require "test_helper"

class AgentAPI::V1::BackgroundQuestionsTest < ActionDispatch::IntegrationTest
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @token = create_access_token_fixture(user: @human, name: "Member")
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::ASK, READ_TOOL])
  end

  test "a detached task can ask while its parent replies and remains answerable during the next turn" do
    turn, agent_run = open_turn
    call_round(agent_run, "r1", "delegate_task", prompt: "Investigate a target")
    branch = running_branch(agent_run)
    call_round(agent_run, branch.node_key, "ask", prompt: "Which target?")

    finish_and_answer(turn, agent_run)
    continuation = running_branch(agent_run)
    assert_includes round_request_entries(continuation).to_json, "staging"
    finish_round(agent_run, continuation.node_key, "Investigation done")
    assert_equal "completed", agent_run.reload.status

    2.times { AgentRuns::ResultDelivery.call(agent_run) }
    mail = @conversation.conversation_inputs.where(origin: "task_result").sole
    assert_includes mail.text, "Investigation done"
    assert_equal "pending", mail.state, "the next turn runs before background mail drains"
    assert_equal "completed", turn.reload.status
  end

  test "a detached question announces itself without withholding the foreground reply" do
    turn, agent_run = open_turn
    call_round(agent_run, "r1", "read_file", path: "context")
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read_file")
    append_branch!(call, [ask("question", "prompt" => "Which target?")])
    schedule_loop!(agent_run)

    finish_and_answer(turn, agent_run)
    assert_equal "completed", agent_run.reload.status
    2.times { AgentRuns::ResultDelivery.call(agent_run) }
    mail = @conversation.conversation_inputs.where(origin: "task_result").sole
    assert_includes mail.text, "staging"
  end

  private

    def open_turn
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(agent_run)
      [turn, agent_run]
    end

    def running_branch(agent_run)
      agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name,
        detached: true, status: "running").sole
    end

    def attempt_for(agent_run, key)
      invocation_id = loop_node(agent_run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round(agent_run, key, name, **arguments)
      apply_via(attempt_for(agent_run, key), sse_success("delegating", tool_calls: [
        { id: "call_#{name}", name: name, arguments: arguments.to_json },
      ]))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::AskJob,
        AgentRuns::ScheduleJob]) do
        AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      end
    end

    def finish_round(agent_run, key, text)
      apply_via(attempt_for(agent_run, key), sse_success(text))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
    end

    def finish_and_answer(turn, agent_run)
      question = agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole
      assert_predicate question, :detached?
      finish_round(agent_run, "r2", "The independent answer is ready")
      assert_predicate agent_run.reload, :delivered?
      assert_equal "awaiting_human", agent_run.attention_reason
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status

      next_turn, = open_turn
      assert_equal next_turn.id, @conversation.reload.active_turn_id
      path = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{agent_run.public_id}"
      get path, headers: { "Authorization" => "Bearer #{@token.secret}" }
      assert_response :success
      assert_equal [question.node_key], response.parsed_body.dig("run", "attention", "blocked_task_keys")
      get "#{path}/tasks/#{question.node_key}", headers: { "Authorization" => "Bearer #{@token.secret}" }
      assert_response :success
      assert_equal "Which target?", response.parsed_body.dig("task", "prompt")
      post "#{path}/tasks/#{question.node_key}/resolution", as: :json,
        headers: { "Authorization" => "Bearer #{@token.secret}" }, params: { content: "staging" }
      assert_response :success
      assert_equal "completed", question.reload.status
      schedule_loop!(agent_run)
      assert_nil agent_run.reload.attention_reason
      assert_equal next_turn.id, @conversation.reload.active_turn_id
    end
end
