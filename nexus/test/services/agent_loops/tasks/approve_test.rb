require "test_helper"

# THE APPROVER'S GRANT: a row resting at `needs_approval` is released past the stage by any
# principal with write standing — the agent application acting for its person included — through THE
# ONE grant site the bypass path also takes. The release re-runs the addressing site: a runner bound
# or handed off during the park is honoured, and a call whose effect profile changed under the park
# RESTS AGAIN with the new profile, because the approver read the profile, not the runner.
class AgentLoops::Tasks::ApproveTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopSeamTestHelper

  MAX_HOLD = AgentLoopNodes::AwaitTask::MAX_HOLD

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def schedule!(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def executor_broadcasts
    broadcasts = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { broadcasts << [stream, payload] }) { yield }
    broadcasts.select { |stream, _payload| stream.start_with?("agent_api:v1:executor:") }
  end

  # A model round calling one tool under `ask`: the fan member parks for
  # its approver; the continuation waits on it.
  def park!(tool_name: "read_file", tools: [LoopLaneTestHelper::READ_TOOL], creating_user: @agent, **shell)
    agent_loop = seed(model("round1", "tools" => tools), creating_user: creating_user,
      approval_mode: "ask", **shell)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: creating_user))
    clear_enqueued_jobs
    schedule!(agent_loop)
    round = node(agent_loop, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("calling", tool_calls: [
      { id: "call_1", name: tool_name, arguments: tool_name == "ask" ? { prompt: "which?" }.to_json : "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_1")
    assert_equal "needs_approval", call.status
    [agent_loop, call]
  end

  def approve(agent_loop, key, acting_user: @human)
    AgentLoops::Tasks::Approve.call(AgentLoops::Tasks::Approve::Command.new(
      agent_loop: agent_loop, task_key: key, acting_user: acting_user
    ))
  end

  def approval_of(node) = node.reload.values_at(:approval_origin, :approved_by_user_id, :approval_decided_at)

  test "a Human's approve releases the row to the runner with the fact stamped, nudges it, and the announcement clears" do
    agent_loop, call = park!
    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, agent_loop.reload.attention_reason

    result, broadcasts = nil
    broadcasts = executor_broadcasts { result = approve(agent_loop, call.node_key) }
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
    assert_operator call.effective_timeout_ms, :<, AgentLoopNodes::AwaitTask::MAX_HOLD_MS, "the run clock now, not the hold"

    stream, payload = broadcasts.sole
    assert_equal AgentAPI::V1::ExecutorInboxChannel.stream_name(suite_runner.public_id), stream
    assert_equal %w[work_available tool_call], [payload.dig(:event, :type), payload.dig(:event, :kind)]

    assert_enqueued_with(job: AgentLoops::ScheduleJob)
    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)
    assert_nil agent_loop.reload.attention_reason, "the pass clears approval_required"
    assert_equal "running", agent_loop.status

    items = agent_loop.conversation_event_items.where(item_type: "task_status")
      .select { |row| row.payload["task_key"] == call.node_key }.map(&:payload)
    assert_equal %w[waiting needs_approval dispatched], items.map { |item| item["status"] }
    assert_equal({ "origin" => "human", "decided_by" => @human.public_id, "decided_at" => call.approval_decided_at.iso8601 },
      items.last.fetch("approval"), "the fact rides the crossing on the stream")
  end

  test "the agent application's own bearer approves as origin agent" do
    agent_loop, call = park!
    assert_predicate approve(agent_loop, call.node_key, acting_user: @agent), :accepted?
    assert_equal ["agent", @agent.id], approval_of(call).first(2)
    assert_equal "dispatched", call.reload.status
    assert_equal "agent", AgentAPI::AgentLoopPresenter.task(call).dig(:approval, "origin")
  end

  # standing pin: a loop-backed loop's verbs read the CONVERSATION's level — a `read` principal is
  # refused before any row is looked at; `full` reaches the row.
  test "a read principal on the hosting conversation has no standing to approve" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, access_default: "read")
    agent_loop = create_loop_backed_turn(conversation: conversation, acting_user: @agent).agent_loop

    assert_equal :not_authorized, approve(agent_loop, "nope").outcome
    conversation.conversation_access_entries.create!(user: @human, level: "full")
    assert_equal :task_not_found, approve(agent_loop, "nope").outcome, "full reaches the row"
  end

  test "the refusals: no write standing, a row not resting, an unknown key, the seam's veto" do
    agent_loop, call = park!
    @workspace.update_column(:state, "archived")
    assert_equal :not_authorized, approve(agent_loop, call.node_key).outcome
    @workspace.update_column(:state, "active")
    agent_loop.reload
    assert_equal "needs_approval", call.reload.status

    assert_equal :task_not_found, approve(agent_loop, "nope").outcome
    assert_equal :not_awaiting_approval, approve(agent_loop, "round1").outcome, "a settled round is not resting"

    assert_predicate approve(agent_loop, call.node_key), :accepted?
    assert_equal :not_awaiting_approval, approve(agent_loop, call.node_key).outcome, "a released row is not resting"

    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: @agent, approval_mode: "ask")
    other = ConversationTurnVariant.create!(account: @account, conversation_turn: seam.turn, position: 1,
      status: "completed", source: "inference")
    seam.turn.update!(active_variant: other)
    assert_equal :not_adjudicable, approve(seam.agent_loop, "any").outcome, "a loop behind a person's edit"
  ensure
    @workspace.update_column(:state, "active")
  end

  test "a paused loop approves with the run clock at the virtual clock, and resume shifts it" do
    agent_loop, call = park!
    paused = AgentLoops::Pause.call(AgentLoops::Pause::Command.new(agent_loop: agent_loop, acting_user: @human, force: false))
    assert_predicate paused, :accepted?
    clear_enqueued_jobs
    frozen_at = agent_loop.reload.paused_at

    travel 10.minutes do
      assert_predicate approve(agent_loop, call.node_key), :accepted?
      call.reload
      assert_equal "dispatched", call.status
      assert_equal frozen_at.floor(6), call.await_started_at.floor(6), "armed at the frozen clock, not the wall"

      resumed = AgentLoops::Resume.call(AgentLoops::Resume::Command.new(agent_loop: agent_loop, acting_user: @human))
      assert_predicate resumed, :accepted?
      assert_in_delta Time.current, call.reload.await_started_at, 1.second, "resume shifts it by the pause, once"
    end
  end

  test "a needs_attention loop approves without releasing its hold" do
    agent_loop, call = park!
    AgentLoops::Transition.agent_loop(agent_loop, status: "needs_attention", attention_reason: "halt_failure")

    assert_predicate approve(agent_loop, call.node_key), :accepted?
    assert_equal "dispatched", call.reload.status
    agent_loop.reload
    assert_equal "needs_attention", agent_loop.status, "the hold is the failure's, never the grant's to release"
    assert_equal "halt_failure", agent_loop.attention_reason
  end

  # THE RE-PARK (r2 (10)): the approver read a PROFILE. When the fresh
  # decision carries another one — the runner re-announced the tool with a
  # different park — the row rests again with the new profile and its
  # clock re-armed, undecided; the next approve releases it.
  test "a call whose effect profile changed under the park rests again with the new profile, then releases" do
    agent_loop, call = park!
    read_before = call.effect_profile
    armed = call.await_started_at
    changed = LoopAuthoringTestHelper::TEST_SERVED_TOOLS.map do |entry|
      entry["name"] == "read_file" ? entry.merge("timeout_ms" => 12_345) : entry
    end
    assert_predicate suite_runner.announce(tools: changed), :accepted?
    assert_not_equal read_before, suite_runner.effect_profile_for("read_file")

    travel 1.minute do
      assert_predicate approve(agent_loop, call.node_key), :accepted?
      call.reload
      assert_equal "needs_approval", call.status, "not released: the person reads the new profile first"
      assert_equal suite_runner.effect_profile_for("read_file"), call.effect_profile
      assert_equal "agent_application", call.addressed_role, "the address stays the agent application"
      assert_operator call.await_started_at, :>, armed, "the clock is re-armed"
      assert_equal [nil, nil, nil], approval_of(call), "nobody decided the call the approver has not read"
      assert_nil call.started_at
      items = agent_loop.conversation_event_items.where(item_type: "task_status")
        .select { |row| row.payload["task_key"] == call.node_key }
      assert_equal %w[waiting needs_approval needs_approval], items.map { |row| row.payload["status"] }, "one narration of the re-park"
      assert_nil items.last.payload["approval"]
    end

    assert_predicate approve(agent_loop, call.node_key), :accepted?
    assert_equal "dispatched", call.reload.status
    assert_equal "human", call.approval_origin
  end

  test "a handoff during the park to a runner announcing the same profile dispatches to the NEW runner" do
    agent_loop, call = park!
    runner_b = connect_runner(manager: users(:owner), runner_identifier: "runner-b", display_name: "B",
      assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate runner_b.announce(tools: LoopAuthoringTestHelper::TEST_SERVED_TOOLS), :accepted?
    handed = Executors::Handoff.call(Executors::Handoff::Command.new(
      host: agent_loop, executor_public_id: runner_b.public_id, acting_user: @agent
    ))
    assert_predicate handed, :accepted?, handed.outcome.to_s
    assert_equal "needs_approval", call.reload.status, "a held row is not the handoff's to move"
    assert_equal "agent_application", call.addressed_role

    assert_predicate approve(agent_loop, call.node_key), :accepted?
    call.reload
    assert_equal "dispatched", call.status
    assert_equal runner_b.id, call.addressed_executor_id, "never the runner the approver did not read about"
  end

  test "a re-run the addressing site refuses fails the row tool_not_served from the stage, on_failure honoured" do
    agent_loop, call = park!
    without_read = LoopAuthoringTestHelper::TEST_SERVED_TOOLS.reject { |entry| entry["name"] == "read_file" }
    assert_predicate suite_runner.announce(tools: without_read), :accepted?

    assert_predicate approve(agent_loop, call.node_key), :accepted?
    call.reload
    assert_equal %w[failed tool_not_served], call.values_at(:status, :error_key)
    assert_equal [nil, nil, nil], approval_of(call), "nothing was granted"
    assert_equal :resolved, AgentLoops::Graph.settlement_of(call), "absorb: the model reads it"
    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)
    assert_equal "running", node(agent_loop, "r1").status
  end

  # A kernel tool row — the model's `ask` — parks under `ask` like any model
  # row (no allow rule names it); the grant runs it in-process, and the
  # executor's after_commit fires exactly as the bypass path's does.
  test "a kernel tool row held under ask approves to running and the kernel executor's after_commit fires" do
    agent_loop, call = park!(tool_name: "ask", tools: [Nexus::Tools::ASK])
    assert_equal "ask", call.tool_name

    assert_predicate approve(agent_loop, call.node_key), :accepted?
    call.reload
    assert_equal "running", call.status
    assert_nil call.addressed_role
    assert_equal "human", call.approval_origin
    assert_enqueued_with(job: AgentLoops::AskJob, args: [call.id])
  end
end
