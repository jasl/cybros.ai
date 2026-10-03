require "test_helper"

class AgentAPI::V1::Executors::ProfileRemovalAdmissionTest < ActionDispatch::IntegrationTest
  include InvocationHarness
  include LoopLaneTestHelper

  TOOL_NAME = "profile_only_read".freeze
  TOOL = {
    "type" => "function",
    "function" => { "name" => TOOL_NAME, "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:owner)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    connection = connect_agent_session(steward: @human, agent_identifier: "profile-removal-admission")
    @executor = connection.executor_access_token.task_executor
    @profile = @executor.agent_profile
    @transport_secret = connection.executor_access_secret
    @member_secret = create_access_token_fixture(user: @human, name: "Profile steward").secret
  end

  test "a removed answerer receives no next tool while asynchronous stop is pending" do
    agent_loop, first = remove_after_commit
    schedule_loop!(agent_loop)
    second = request_tool(agent_loop, "after_removal")
    assert_equal ["failed", "tool_not_served"], second.values_at(:status, :error_key),
      "a surviving Human speaker does not reopen admission to the removed answerer's executor"
    assert_nil second.addressed_executor_id
    assert_equal "the accepted work finished", first.reload.output_preview
    assert_equal 2, @executor.reload.credential_epoch
  end

  test "a next-round ask after Profile removal keeps only the Human's answer door" do
    agent_loop, = remove_after_commit(tools: [TOOL, Nexus::Tools::ASK])
    schedule_loop!(agent_loop)
    apply_via(loop_attempt(agent_loop), sse_success("asking", tool_calls: [
      { id: "after_removal", name: "ask", arguments: { prompt: "which file?" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end

    asked = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::AwaitTask.sti_name).sole
    assert_equal "awaiting_input", asked.status
    assert_nil asked.addressed_executor_id
    assert_nil asked.addressed_role
    assert_nil asked.resolution_token, "the model's ask is answered by write standing"

    post "#{tasks_path(agent_loop)}/#{asked.node_key}/resolution", headers: member_bearer, as: :json,
      params: { content: "notes.md" }
    assert_response :success
    assert_equal "completed", asked.reload.status
    assert_equal "notes.md", asked.output_body.effective_text
  end

  test "a next-round approval after Profile removal keeps the Human's grant door" do
    agent_loop, = remove_after_commit(tools: [TOOL, READ_TOOL], approval_mode: "ask", runner: suite_runner)
    schedule_loop!(agent_loop)
    held = request_tool(agent_loop, "after_removal", name: "read_file")
    assert_equal "needs_approval", held.status
    assert_nil held.addressed_executor_id
    assert_nil held.addressed_role
    assert_not_nil held.effect_profile

    post "#{tasks_path(agent_loop)}/#{held.node_key}/approve", headers: member_bearer, as: :json
    assert_response :success
    assert_equal ["dispatched", suite_runner.id, "human"],
      held.reload.values_at(:status, :addressed_executor_id, :approval_origin)
    assert_equal @human.id, held.approved_by_user_id
  end

  test "reconnecting the restored Profile lets the same address claim new work with fresh credentials" do
    agent_loop, = remove_after_commit
    assert_equal :restored, @profile.restore
    assert_equal @executor.id, TaskExecutor.address_for(@profile).id
    assert_not @executor.reload.eligible_for?(@human), "restore does not revive fenced credentials"
    get agent_api_v1_executor_inbox_path, headers: bearer
    assert_response :unauthorized

    connection = connect_agent_session(steward: @human, agent_identifier: @profile.agent_identifier)
    assert_equal @executor, connection.executor_access_token.task_executor
    @transport_secret = connection.executor_access_secret
    assert @executor.reload.eligible_for?(@human)

    schedule_loop!(agent_loop)
    next_task = request_tool(agent_loop, "after_restore")
    assert_equal ["dispatched", @executor.id], next_task.values_at(:status, :addressed_executor_id)
    claim_token = claim(agent_loop, next_task)
    commit(agent_loop, next_task, claim_token)
    assert_equal "completed", next_task.reload.status
    assert_equal 3, @executor.reload.credential_epoch
  end

  test "removal rejects an existing claim before asynchronous stopping runs" do
    declare_tools!(@profile, tools: [TOOL])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: @profile)
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: @human)
    schedule_loop!(agent_loop)
    task = request_tool(agent_loop, "claimed_before_removal")
    token = claim(agent_loop, task)

    assert_enqueued_with(job: Users::StopAgentWorkJob, args: [@profile.id]) do
      assert_equal :removed, Users::Remove.call(user: @profile)
    end
    assert_equal "dispatched", task.reload.status, "work cleanup is asynchronous"
    post agent_api_v1_executor_inbox_commit_path(agent_loop_public_id: agent_loop.public_id,
      task_key: task.node_key), headers: bearer, as: :json,
      params: { claim_token: token, content: "late", outcome: "completed" }
    assert_response :unauthorized
    assert_equal "dispatched", task.reload.status

    Users::StopAgentWorkJob.perform_now(@profile.id)
    assert_equal "canceled", task.reload.status
    assert_nil task.output_body
  end

  private

    def bearer = { "Authorization" => "Bearer #{@transport_secret}" }

    def member_bearer = { "Authorization" => "Bearer #{@member_secret}" }

    def tasks_path(agent_loop)
      "/agent_api/v1/workspaces/#{@workspace.public_id}/agent_loops/#{agent_loop.public_id}/tasks"
    end

    def remove_after_commit(tools: [TOOL], approval_mode: "bypass", runner: nil)
      declare_tools!(@profile, tools: tools, approval_mode: approval_mode)
      conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
        answering_user: @profile, runner_executor: runner)
      _turn, agent_loop = materialize_loop_reply!(conversation, agent: @human)
      assert_equal @human, agent_loop.creating_user
      assert_equal @profile, agent_loop.answering_user
      if runner
        assert_equal runner, agent_loop.bound_runner
      else
        assert_nil agent_loop.bound_runner
      end
      schedule_loop!(agent_loop)
      first = request_tool(agent_loop, "before_removal")
      if approval_mode == "ask"
        post "#{tasks_path(agent_loop)}/#{first.node_key}/approve", headers: member_bearer, as: :json
        assert_response :success
        first.reload
      end
      assert_equal ["dispatched", @executor.id], first.values_at(:status, :addressed_executor_id)
      claim_token = claim(agent_loop, first)

      commit(agent_loop, first, claim_token)
      assert_equal "completed", first.reload.status
      assert_equal :removed, @profile.remove
      assert_predicate @executor.reload, :active?
      assert_equal 2, @executor.credential_epoch
      assert_not @executor.eligible_for?(@human), "an active speaker cannot admit work to a removed Profile"
      [agent_loop, first]
    end

    def claim(agent_loop, task)
      post agent_api_v1_executor_inbox_claim_path(agent_loop_public_id: agent_loop.public_id,
        task_key: task.node_key), headers: bearer, as: :json
      assert_response :success
      response.parsed_body.fetch("claim").fetch("claim_token")
    end

    def commit(agent_loop, task, claim_token)
      post agent_api_v1_executor_inbox_commit_path(agent_loop_public_id: agent_loop.public_id,
        task_key: task.node_key), headers: bearer, as: :json,
        params: { claim_token: claim_token, content: "the accepted work finished", outcome: "completed" }
      assert_response :success
    end

    def request_tool(agent_loop, call_id, name: TOOL_NAME)
      run_loop_round!(agent_loop, sse_success("reading", tool_calls: [
        { id: call_id, name: name, arguments: "{}" },
      ]))
      agent_loop.agent_loop_nodes.find_by!(tool_call_id: call_id)
    end
end
