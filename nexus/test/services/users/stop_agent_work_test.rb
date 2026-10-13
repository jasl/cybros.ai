require "test_helper"

class Users::StopAgentWorkTest < ActionDispatch::IntegrationTest
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "force stop cancels a Runner claim without revoking the Runner or changing its accepted sibling" do
    declare_tools!(@agent, tools: fixture_runner_declarations([READ_TOOL]))
    @agent.update!(runner_executor_public_ids: [suite_runner.public_id])
    conversation = room(answerer: @agent, default_runner_executor: suite_runner)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @human)
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("read both", tool_calls: [
      { id: "accepted", name: "read_file", arguments: "{}" },
      { id: "claimed", name: "read_file", arguments: "{}" },
    ]))
    accepted = agent_run.agent_run_tasks.find_by!(tool_call_id: "accepted")
    claimed = agent_run.agent_run_tasks.find_by!(tool_call_id: "claimed")
    accepted_token = claim(agent_run, accepted)
    post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id,
      task_key: accepted.node_key), headers: runner_bearer, as: :json,
      params: { claim_token: accepted_token, content: "already accepted", outcome: "completed" }
    assert_response :success
    claimed_token = claim(agent_run, claimed)
    epoch = suite_runner.credential_epoch

    assert_equal :removed, @agent.remove
    assert_equal "dispatched", claimed.reload.status
    clear_enqueued_jobs
    2.times { Users::StopAgentWorkJob.perform_now(@agent.id) }

    assert_equal ["canceled", "run_canceled"], claimed.reload.values_at(:status, :error_key)
    assert_nil claimed.output_body
    assert_equal "completed", accepted.reload.status
    assert_equal "already accepted", accepted.output_body.effective_text
    assert_equal epoch, suite_runner.reload.credential_epoch
    get agent_api_v1_executor_inbox_path, headers: runner_bearer
    assert_response :success
    [[claimed, claimed_token], [accepted, accepted_token]].each do |node, token|
      post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id,
        task_key: node.node_key), headers: runner_bearer, as: :json,
        params: { claim_token: token, content: "late replacement", outcome: "completed" }
      assert_response :success
    end
    assert_equal "canceled", claimed.reload.status
    assert_nil claimed.output_body
    assert_equal "already accepted", accepted.reload.output_body.effective_text
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    Conversations::Turns::Converge.call
    assert_equal "canceled", agent_run.reload.status
    assert_equal "canceled", agent_run.conversation_turn.reload.status
  end

  test "current roles stop pending turns even when no variant has been allocated" do
    default = pending_turn(room(answerer: @agent))
    creator = pending_turn(room(creator: @agent))
    answerer = pending_turn(room, answerer: @agent)
    author = pending_turn(room, owner: @agent)
    unrelated = pending_turn(room)
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs

    Users::StopAgentWorkJob.perform_now(@agent.id)

    [default, creator, answerer, author].each do |turn|
      assert_equal "canceled", turn.reload.status
      assert_nil turn.conversation.reload.active_turn_id
    end
    assert_equal "pending", unrelated.reload.status
  end

  test "Human shutdown convergence fences the Agent credentials before its queued wake stops claimed work" do
    steward = users(:member)
    connection = connect_agent_session(steward: steward, agent_identifier: "steward-stop-work")
    executor = connection.executor_access_token.task_executor
    profile = executor.agent
    member_bearer = { "Authorization" => "Bearer #{connection.access_secret}" }
    transport_bearer = { "Authorization" => "Bearer #{connection.executor_access_secret}" }
    declare_tools!(profile)
    conversation = room(answerer: profile)
    turn, agent_run = materialize_loop_reply!(conversation, agent: @human)
    assert_nil agent_run.default_runner
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("reading", tool_calls: [
      { id: "before_shutdown", name: "read_file", arguments: "{}" },
    ]))
    task = agent_run.agent_run_tasks.find_by!(tool_call_id: "before_shutdown")
    assert_equal executor.id, task.addressed_executor_id
    post agent_api_v1_executor_inbox_claim_path(run_public_id: agent_run.public_id,
      task_key: task.node_key), headers: transport_bearer, as: :json
    assert_response :success
    token = response.parsed_body.fetch("claim").fetch("claim_token")
    get agent_api_v1_profile_path, headers: member_bearer
    assert_response :success
    epoch = executor.reload.credential_epoch
    clear_enqueued_jobs

    assert_equal :removed, Users::Remove.call(user: steward)
    assert_predicate profile.reload, :active?
    assert_no_enqueued_jobs(only: Users::StopAgentWorkJob)
    assert_enqueued_with(job: Users::StopAgentWorkJob, args: []) do
      Users::ConvergeJob.perform_now
    end
    assert_predicate profile.reload, :removed?
    assert_equal epoch + 1, executor.reload.credential_epoch
    assert_equal "dispatched", task.reload.status, "Profile convergence leaves work cleanup to its wake"

    get agent_api_v1_profile_path, headers: member_bearer
    assert_response :unauthorized
    post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id,
      task_key: task.node_key), headers: transport_bearer, as: :json,
      params: { claim_token: token, content: "late result", outcome: "completed" }
    assert_response :unauthorized
    assert_equal "dispatched", task.reload.status
    assert_nil task.output_body

    perform_enqueued_jobs(only: Users::StopAgentWorkJob)
    assert_equal ["canceled", "run_canceled"], task.reload.values_at(:status, :error_key)
    assert_nil task.output_body
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    Conversations::Turns::Converge.call
    assert_equal "canceled", agent_run.reload.status
    assert_equal "canceled", turn.reload.status
    assert_nil conversation.reload.active_turn_id
  end

  test "the recovery floor cancels an ordinary reply without an AgentRun" do
    conversation = room(answerer: @agent)
    post_input!(conversation, acting_user: @human, kind: "direct_reply", text: "answer this",
      provider_id: "dev", model_ref: "mock-text")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    turn = conversation.conversation_turns.sole
    assert_equal "inference", turn.active_variant.source
    assert_nil turn.active_variant.agent_run
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs

    Users::StopAgentWorkJob.perform_now
    Conversations::Turns::Converge.call

    assert_equal "canceled", turn.active_variant.model_invocation.reload.status
    assert_equal "canceled", turn.reload.status
    assert_nil conversation.reload.active_turn_id
  end

  test "stopping an old delivered background loop leaves another answerer's current turn running" do
    peer = connect_agent_session(steward: @human, agent_identifier: "stop-work-peer")
      .executor_access_token.task_executor.agent
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, READ_TOOL])
    declare_tools!(peer)
    conversation = room(answerer: peer)
    _turn, background = materialize_loop_reply!(conversation, agent: @human,
      answering_user_public_id: @agent.public_id)
    schedule_loop!(background)
    answer(background, "r1", "delegating", calls: [{
      id: "background", name: "delegate_task", arguments: { prompt: "check slowly" }.to_json,
    }])
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: background.id)
    end
    answer(background, "r2", "I will report later")
    Conversations::Turns::Converge.call
    assert_predicate background.reload, :delivered?
    assert_equal "running", background.status
    _current_turn, current = materialize_loop_reply!(conversation.reload, agent: @human)
    schedule_loop!(current)
    current_invocation = ModelInvocation.find(loop_node(current, "r1").selected_model_invocation_id)
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs

    Users::StopAgentWorkJob.perform_now
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: background.id)
    Conversations::Turns::Converge.call

    assert_equal "canceled", background.reload.status
    assert_equal "completed", background.conversation_turn.reload.status
    assert_equal "running", current.reload.status
    assert_equal "running", current.conversation_turn.reload.status
    assert_not current_invocation.reload.terminal?
    assert_equal current.conversation_turn.id, conversation.reload.active_turn_id
  end

  test "lost wakes recover pending paused held and gracefully canceling standalone loops" do
    pending = seed(ask("pending"), creating_user: @agent)
    paused = start_ask("paused")
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: paused, acting_user: @human
    )), :accepted?
    held = start_ask("held")
    held.agent_run_tasks.find_by!(node_key: "held").update_columns(await_started_at: 2.days.ago)
    AgentRuns::Parks::TimeoutSweep.call
    assert_equal "needs_attention", held.reload.status
    canceling = start_ask("canceling")
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: canceling, acting_user: @human, force: false
    )), :accepted?
    assert_equal "canceling", canceling.reload.status
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs

    Users::StopAgentWorkJob.perform_now
    [pending, paused, held, canceling].each do |agent_run|
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      assert_equal "canceled", agent_run.reload.status
    end
    assert_nil paused.reload.paused_at
    assert_equal "timed_out", held.agent_run_tasks.find_by!(node_key: "held").status,
      "force stop preserves a failure already recorded before removal"
  end

  test "spawned descendants stop while a fork's shared history does not confer a stop relationship" do
    root = room(creator: @agent)
    child = room(parent_conversation: root)
    grandchild = room(parent_conversation: child)
    descendants = [child, grandchild].map { |conversation| pending_turn(conversation) }
    source_turn = pending_turn(root)
    source_turn.update!(status: "completed")
    root.update!(active_turn: nil)
    fork = room
    ConversationAncestry.create!(account: @account, conversation: fork,
      ancestor_conversation: root, depth: 1, boundary_position: source_turn.position)
    survivor = pending_turn(fork, position: source_turn.position + 1)
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs

    Users::StopAgentWorkJob.perform_now

    descendants.each { |turn| assert_equal "canceled", turn.reload.status }
    assert_equal "pending", survivor.reload.status
  end

  test "a spawned child's commissioning turn survives as its stop relationship without stopping a newer parent turn" do
    peer = connect_agent_session(steward: @human, agent_identifier: "stop-spawn-peer")
      .executor_access_token.task_executor.agent
    declare_tools!(peer, tools: [Nexus::Tools::SPAWN, READ_TOOL])
    parent = room(answerer: peer)
    _turn, commissioning = materialize_loop_reply!(parent, agent: @agent)
    schedule_loop!(commissioning)
    answer(commissioning, "r1", "delegate", calls: [{
      id: "child", name: "spawn", arguments: { prompt: "work slowly" }.to_json,
    }])
    perform_enqueued_jobs(only: [AgentRuns::ConversationToolJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: commissioning.id)
    end
    child = Conversation.find_by!(spawn_node_id: loop_node(commissioning, "r2t0").id)
    assert_equal peer, child.creating_user
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_loop = child.conversation_turns.sole.active_variant.agent_run
    answer(commissioning, "r2", "done delegating")
    Conversations::Turns::Converge.call
    assert_equal "completed", commissioning.reload.status
    _turn, current = materialize_loop_reply!(parent.reload, agent: @human)
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs

    Users::StopAgentWorkJob.perform_now
    AgentRuns::ScheduleReady.call(agent_run_id: child_loop.id)

    assert_equal "canceled", child_loop.reload.status
    assert_equal "running", current.reload.status
    assert_equal "running", current.conversation_turn.reload.status
  end

  test "restore between discovery and the target lock protects old and newly accepted work" do
    conversation = room(answerer: @agent)
    old = pending_turn(conversation)
    assert_equal :removed, @agent.remove
    service = Users::StopAgentWork.new(user_id: @agent.id)
    discover = service.method(:related_conversations)
    first = true
    service.stub(:related_conversations, ->(ids) {
      matches = discover.call(ids)
      if first
        first = false
        assert_equal [conversation.id], matches
        assert_equal :restored, @agent.restore
      end
      matches
    }) { service.call }
    assert_equal "pending", old.reload.status
    fresh = pending_turn(room(answerer: @agent))
    Users::StopAgentWorkJob.perform_now(@agent.id)
    Users::StopAgentWorkJob.perform_now
    assert_equal ["pending", "pending"], [old.reload.status, fresh.reload.status]
  end

  test "one after-commit removal wake stops the parent and instance definition but preserves a published definition" do
    configuration = {
      tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "default",
      prompt_template: nil, compaction_policy: nil, default_model: nil,
    }
    instance, published = [["private_helper", "instance"], ["published_helper", "steward"]].map do |name, scope|
      declared = Users::DeclareNamedDefinition.call(caller: @agent, name: name, scope: scope,
        description: "Reviews a task.", configuration: configuration)
      assert_predicate declared, :accepted?
      declared.user
    end
    parent_turn = pending_turn(room(answerer: @agent))
    instance_turn = pending_turn(room(answerer: instance))
    published_turn = pending_turn(room(answerer: published))
    clear_enqueued_jobs

    assert_enqueued_with(job: Users::StopAgentWorkJob, args: [@agent.id]) do
      User.transaction do
        assert_equal :removed, Users::Remove.call(user: @agent)
        assert_no_enqueued_jobs(only: Users::StopAgentWorkJob)
      end
    end
    assert_predicate instance.reload, :removed?
    assert_predicate published.reload, :active?
    assert_equal ["pending", "pending"], [parent_turn.reload.status, instance_turn.reload.status],
      "the authority transaction does not stop Conversation work"

    perform_enqueued_jobs(only: Users::StopAgentWorkJob)

    assert_equal ["canceled", "canceled"], [parent_turn.reload.status, instance_turn.reload.status]
    assert_equal "pending", published_turn.reload.status
    assert_predicate published.reload, :active?
    assert_no_enqueued_jobs(only: Users::StopAgentWorkJob)
  end

  private

    def room(creator: @human, answerer: @human, **attributes)
      Conversation.create!(workspace: @workspace, creating_user: creator,
        answering_user: answerer, **attributes)
    end

    def pending_turn(conversation, answerer: conversation.answering_user, owner: @human, position: 0)
      turn = conversation.conversation_turns.create!(position: position, kind: "direct_reply",
        role: "assistant", status: "pending", control_owner_user: owner,
        speaker: Speakers::Resolve.member(account: @account, user: owner), answering_user: answerer)
      conversation.update!(active_turn: turn, timeline_position_head: position + 1)
      turn
    end

    def runner_bearer = { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }

    def claim(agent_run, node)
      post agent_api_v1_executor_inbox_claim_path(run_public_id: agent_run.public_id,
        task_key: node.node_key), headers: runner_bearer, as: :json
      assert_response :success
      response.parsed_body.fetch("claim").fetch("claim_token")
    end

    def answer(agent_run, key, text, calls: [])
      invocation_id = loop_node(agent_run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      attempt = ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
      apply_via(attempt, sse_success(text, tool_calls: calls))
      AgentRuns::ConvergeTerminalSteps.call
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) if calls.empty?
    end

    def start_ask(key)
      agent_run = seed(ask(key), creating_user: @agent)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @agent
      )), :accepted?
      schedule_loop!(agent_run)
      agent_run
    end
end
