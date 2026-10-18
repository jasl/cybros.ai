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
    turn, run = open_turn
    call_round(run, "r1", "delegate_task", prompt: "Investigate a target")
    branch = running_branch(run)
    call_round(run, branch.node_key, "ask", prompt: "Which target?")

    finish_and_answer(turn, run)
    continuation = running_branch(run)
    assert_includes round_request_entries(continuation).to_json, "staging"
    finish_round(run, continuation.node_key, "Investigation done")
    assert_equal "completed", run.reload.status

    2.times { Runs::ResultDelivery.call(run) }
    mail = @conversation.inputs.where(origin: "task_result").sole
    assert_includes mail.text, "Investigation done"
    assert_equal "pending", mail.state, "the next turn runs before background mail drains"
    assert_equal "completed", turn.reload.status
  end

  test "a detached question announces itself without withholding the foreground reply" do
    turn, run = open_turn
    call_round(run, "r1", "read_file", path: "context")
    call = run.tasks.find_by!(tool_call_id: "call_read_file")
    append_branch!(call, [ask("question", "prompt" => "Which target?")])
    schedule_loop!(run)

    finish_and_answer(turn, run)
    assert_equal "completed", run.reload.status
    2.times { Runs::ResultDelivery.call(run) }
    mail = @conversation.inputs.where(origin: "task_result").sole
    assert_includes mail.text, "staging"
  end

  private

    def open_turn
      turn, run = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(run)
      [turn, run]
    end

    def running_branch(run)
      run.tasks.where(type: Tasks::ModelTask.sti_name,
        detached: true, status: "running").sole
    end

    def attempt_for(run, key)
      invocation_id = loop_node(run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round(run, key, name, **arguments)
      apply_via(attempt_for(run, key), sse_success("delegating", tool_calls: [
        { id: "call_#{name}", name: name, arguments: arguments.to_json },
      ]))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [Runs::DelegateTaskToolJob, Runs::AskJob,
        Runs::ScheduleJob]) do
        Runs::ScheduleReady.call(run_id: run.id)
      end
    end

    def finish_round(run, key, text)
      apply_via(attempt_for(run, key), sse_success(text))
      Runs::ConvergeTerminalSteps.call
      schedule_loop!(run)
    end

    def finish_and_answer(turn, run)
      question = run.tasks.where(type: Tasks::AwaitTask.sti_name).sole
      assert_predicate question, :detached?
      finish_round(run, "r2", "The independent answer is ready")
      assert_predicate run.reload, :delivered?
      assert_equal "awaiting_human", run.attention_reason
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status

      next_turn, = open_turn
      assert_equal next_turn.id, @conversation.reload.active_turn_id
      path = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{run.public_id}"
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
      schedule_loop!(run)
      assert_nil run.reload.attention_reason
      assert_equal next_turn.id, @conversation.reload.active_turn_id
    end
end
