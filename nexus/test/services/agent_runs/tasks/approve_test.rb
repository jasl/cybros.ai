require "test_helper"

# THE APPROVER'S GRANT: a row resting at `needs_approval` is released past the stage by any
# principal with write standing — the agent application acting for its person included — through THE
# ONE grant site the bypass path also takes. Release revalidates the accepted target, independently
# of the host's current default. A changed effect profile rests again for another approval.
class AgentRuns::Tasks::ApproveTest < ActiveJob::TestCase
  include InvocationHarness
  include RunSeamTestHelper

  MAX_HOLD = AgentRunTasks::AwaitTask::MAX_HOLD

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def executor_broadcasts
    broadcasts = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { broadcasts << [stream, payload] }) { yield }
    broadcasts.select { |stream, _payload| stream.start_with?("agent_api:v1:executor:") }
  end

  # A model round calling one tool under `ask`: the fan member parks for
  # its approver; the continuation waits on it.
  def park!(tool_name: "read_file", tools: [RunLaneTestHelper::READ_TOOL], creating_user: @agent, **shell)
    agent_run = seed(model("round1", "tools" => tools), creating_user: creating_user,
      approval_mode: "ask", **shell)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: creating_user))
    clear_enqueued_jobs
    schedule!(agent_run)
    round = node(agent_run, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("calling", tool_calls: [
      { id: "call_1", name: tool_name, arguments: tool_name == "ask" ? { prompt: "which?" }.to_json : "{}" },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_1")
    assert_equal "needs_approval", call.status
    [agent_run, call]
  end

  def approve(agent_run, key, acting_user: @human)
    AgentRuns::Tasks::Approve.call(AgentRuns::Tasks::Approve::Command.new(
      agent_run: agent_run, task_key: key, acting_user: acting_user
    ))
  end

  def approval_of(node) = node.reload.values_at(:approval_origin, :approved_by_user_id, :approval_decided_at)

  test "a Human's approve releases the row to the runner with the fact stamped, nudges it, and the announcement clears" do
    agent_run, call = park!
    assert_equal AgentRuns::EvaluateQuiescence::APPROVAL_REASON, agent_run.reload.attention_reason

    result, broadcasts = nil
    broadcasts = executor_broadcasts { result = approve(agent_run, call.node_key) }
    assert_predicate result, :accepted?
    assert_equal call.id, result.node.id

    call.reload
    assert_equal "dispatched", call.status
    assert_equal suite_runner.id, call.addressed_executor_id, "re-addressed by the one site: the runner, not the approver"
    assert_equal "runner", call.addressed_role
    assert_equal suite_runner.effect_profile_for("read_file"), call.effect_profile
    assert_not_nil call.started_at
    assert_equal ["human", @human.id], approval_of(call).first(2)
    assert_not_nil call.approval_decided_at
    assert_equal call.await_started_at + (call.effective_timeout_ms / 1000.0), call.deadline_at
    assert_operator call.effective_timeout_ms, :<, AgentRunTasks::AwaitTask::MAX_HOLD_MS, "the run clock now, not the hold"

    stream, payload = broadcasts.sole
    assert_equal AgentAPI::V1::ExecutorInboxChannel.stream_name(suite_runner.public_id), stream
    assert_equal %w[work_available tool_call], [payload.dig(:event, :type), payload.dig(:event, :kind)]

    assert_enqueued_with(job: AgentRuns::ScheduleJob)
    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)
    assert_nil agent_run.reload.attention_reason, "the pass clears approval_required"
    assert_equal "running", agent_run.status

    items = agent_run.conversation_event_items.where(item_type: "task_status")
      .select { |row| row.payload["task_key"] == call.node_key }.map(&:payload)
    assert_equal %w[waiting needs_approval dispatched], items.map { |item| item["status"] }
    assert_equal({ "origin" => "human", "decided_by" => @human.public_id, "decided_at" => call.approval_decided_at.iso8601 },
      items.last.fetch("approval"), "the fact rides the crossing on the stream")
  end

  test "the agent application's own bearer approves as origin agent" do
    agent_run, call = park!
    assert_predicate approve(agent_run, call.node_key, acting_user: @agent), :accepted?
    assert_equal ["agent", @agent.id], approval_of(call).first(2)
    assert_equal "dispatched", call.reload.status
    assert_equal "agent", AgentAPI::AgentRunPresenter.task(call).dig(:approval, "origin")
  end

  # standing pin: a loop-backed loop's verbs read the CONVERSATION's level — a `read` principal is
  # refused before any row is looked at; `full` reaches the row.
  test "a read principal on the hosting conversation has no standing to approve" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, access_default: "read")
    agent_run = create_run_backed_turn(conversation: conversation, acting_user: @agent).agent_run

    assert_equal :not_authorized, approve(agent_run, "nope").outcome
    conversation.conversation_access_entries.create!(user: @human, level: "full")
    assert_equal :task_not_found, approve(agent_run, "nope").outcome, "full reaches the row"
  end

  test "the refusals: no write standing, a row not resting, an unknown key, the seam's veto" do
    agent_run, call = park!
    @workspace.update_column(:state, "archived")
    assert_equal :not_authorized, approve(agent_run, call.node_key).outcome
    @workspace.update_column(:state, "active")
    agent_run.reload
    assert_equal "needs_approval", call.reload.status

    assert_equal :task_not_found, approve(agent_run, "nope").outcome
    assert_equal :not_awaiting_approval, approve(agent_run, "round1").outcome, "a settled round is not resting"

    assert_predicate approve(agent_run, call.node_key), :accepted?
    assert_equal :not_awaiting_approval, approve(agent_run, call.node_key).outcome, "a released row is not resting"

    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @agent, approval_mode: "ask")
    other = ConversationTurnVariant.create!(account: @account, conversation_turn: seam.turn, position: 1,
      status: "completed", source: "inference")
    seam.turn.update!(active_variant: other)
    assert_equal :not_adjudicable, approve(seam.agent_run, "any").outcome, "a loop behind a person's edit"
  ensure
    @workspace.update_column(:state, "active")
  end

  test "a paused loop approves with the run clock at the virtual clock, and resume shifts it" do
    agent_run, call = park!
    paused = AgentRuns::Pause.call(AgentRuns::Pause::Command.new(agent_run: agent_run, acting_user: @human, force: false))
    assert_predicate paused, :accepted?
    clear_enqueued_jobs
    frozen_at = agent_run.reload.paused_at

    travel 10.minutes do
      assert_predicate approve(agent_run, call.node_key), :accepted?
      call.reload
      assert_equal "dispatched", call.status
      assert_equal frozen_at.floor(6), call.await_started_at.floor(6), "armed at the frozen clock, not the wall"

      resumed = AgentRuns::Resume.call(AgentRuns::Resume::Command.new(agent_run: agent_run, acting_user: @human))
      assert_predicate resumed, :accepted?
      assert_in_delta Time.current, call.reload.await_started_at, 1.second, "resume shifts it by the pause, once"
    end
  end

  test "a needs_attention loop approves without releasing its hold" do
    agent_run, call = park!
    AgentRuns::Transition.agent_run(agent_run, status: "needs_attention", attention_reason: "halt_failure")

    assert_predicate approve(agent_run, call.node_key), :accepted?
    assert_equal "dispatched", call.reload.status
    agent_run.reload
    assert_equal "needs_attention", agent_run.status, "the hold is the failure's, never the grant's to release"
    assert_equal "halt_failure", agent_run.attention_reason
  end

  # THE RE-PARK (r2 (10)): the approver read a PROFILE. When the fresh
  # decision carries another one — the runner re-announced the tool with a
  # different park — the row rests again with the new profile and its
  # clock re-armed, undecided; the next approve releases it.
  test "a call whose effect profile changed under the park rests again with the new profile, then releases" do
    agent_run, call = park!
    read_before = call.effect_profile
    armed = call.await_started_at
    changed = RunAuthoringTestHelper::TEST_SERVED_TOOLS.map do |entry|
      entry["name"] == "read_file" ? entry.merge("timeout_ms" => 12_345) : entry
    end
    assert_predicate suite_runner.announce(tools: changed), :accepted?
    assert_not_equal read_before, suite_runner.effect_profile_for("read_file")

    travel 1.minute do
      assert_predicate approve(agent_run, call.node_key), :accepted?
      call.reload
      assert_equal "needs_approval", call.status, "not released: the person reads the new profile first"
      assert_equal suite_runner.effect_profile_for("read_file"), call.effect_profile
      assert_equal "agent_application", call.addressed_role, "the address stays the agent application"
      assert_operator call.await_started_at, :>, armed, "the clock is re-armed"
      assert_equal [nil, nil, nil], approval_of(call), "nobody decided the call the approver has not read"
      assert_nil call.started_at
      items = agent_run.conversation_event_items.where(item_type: "task_status")
        .select { |row| row.payload["task_key"] == call.node_key }
      assert_equal %w[waiting needs_approval needs_approval], items.map { |row| row.payload["status"] }, "one narration of the re-park"
      assert_nil items.last.payload["approval"]
    end

    assert_predicate approve(agent_run, call.node_key), :accepted?
    assert_equal "dispatched", call.reload.status
    assert_equal "human", call.approval_origin
  end

  test "a default change during approval preserves the accepted target and hold clock" do
    agent_run, call = park!
    target = call.target_executor_public_id
    armed = call.await_started_at
    runner_b = connect_runner(manager: users(:owner), registration_identifier: "runner-b", display_name: "B",
      assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate runner_b.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS), :accepted?
    selected = Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: agent_run, executor_public_id: runner_b.public_id, acting_user: @agent
    ))
    assert_predicate selected, :accepted?, selected.outcome.to_s
    assert_equal "needs_approval", call.reload.status
    assert_equal "agent_application", call.addressed_role
    assert_equal target, call.target_executor_public_id
    assert_equal armed, call.await_started_at

    assert_predicate approve(agent_run, call.node_key), :accepted?
    call.reload
    assert_equal "dispatched", call.status
    assert_equal suite_runner.id, call.addressed_executor_id
    assert_equal target, call.target_executor_public_id
    assert_equal runner_b.id, agent_run.reload.default_runner_executor_id
  end

  test "a re-run the addressing site refuses fails the row tool_not_served from the stage, on_failure honoured" do
    agent_run, call = park!
    without_read = RunAuthoringTestHelper::TEST_SERVED_TOOLS.reject { |entry| entry["name"] == "read_file" }
    assert_predicate suite_runner.announce(tools: without_read), :accepted?

    assert_predicate approve(agent_run, call.node_key), :accepted?
    call.reload
    assert_equal %w[failed tool_not_served], call.values_at(:status, :error_key)
    assert_equal [nil, nil, nil], approval_of(call), "nothing was granted"
    assert_equal :resolved, AgentRuns::Graph.settlement_of(call), "absorb: the model reads it"
    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)
    assert_equal "running", node(agent_run, "r1").status
  end

  # A kernel tool row — the model's `ask` — parks under `ask` like any model
  # row (no allow rule names it); the grant runs it in-process, and the
  # executor's after_commit fires exactly as the bypass path's does.
  test "a kernel tool row held under ask approves to running and the kernel executor's after_commit fires" do
    agent_run, call = park!(tool_name: "ask", tools: [Nexus::Tools::ASK])
    assert_equal "ask", call.tool_name

    assert_predicate approve(agent_run, call.node_key), :accepted?
    call.reload
    assert_equal "running", call.status
    assert_nil call.addressed_role
    assert_equal "human", call.approval_origin
    assert_enqueued_with(job: AgentRuns::AskJob, args: [call.id])
  end
end
