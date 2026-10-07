require "test_helper"

# THE APPROVER'S REFUSAL: a row resting at `needs_approval` fails `approval_denied` with the
# person's reason as the detail, the fact stamped; the row's own `on_failure` decides the cascade —
# a model-composed call is `absorb`, so the next round reads the declined sentence and corrects
# itself; an authored `halt` step holds, and a retry parks it again at its next start.
class AgentRuns::Tasks::DenyTest < ActiveJob::TestCase
  include InvocationHarness

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

  def park!
    agent_run = seed(model("round1", "tools" => [RunLaneTestHelper::READ_TOOL]), creating_user: @agent,
      approval_mode: "ask")
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @agent))
    clear_enqueued_jobs
    schedule!(agent_run)
    round = node(agent_run, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("reading", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read")
    assert_equal "needs_approval", call.status
    [agent_run, call]
  end

  def deny(agent_run, key, reason: nil, acting_user: @human)
    AgentRuns::Tasks::Deny.call(AgentRuns::Tasks::Deny::Command.new(
      agent_run: agent_run, task_key: key, acting_user: acting_user, reason: reason
    ))
  end

  def paired_results(agent_run, key)
    ModelInvocation.find(node(agent_run, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
      .select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  test "deny with a reason fails the row approval_denied, stamps the fact, and the next round reads the declined sentence" do
    agent_run, call = park!
    result = deny(agent_run, call.node_key, reason: "use ls")
    assert_predicate result, :accepted?

    call.reload
    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_equal "use ls", call.error_detail
    assert_equal ["human", @human.id], call.values_at(:approval_origin, :approved_by_user_id)
    assert_not_nil call.approval_decided_at
    assert_not_nil call.completed_at
    assert_nil call.started_at, "nothing was dispatched"
    assert_nil call.failure_resolution, "absorb resolves by derivation"
    assert_equal :resolved, AgentRuns::Graph.settlement_of(call)

    items = agent_run.conversation_event_items.where(item_type: "task_status")
      .select { |row| row.payload["task_key"] == call.node_key }.map(&:payload)
    assert_equal %w[waiting needs_approval failed failed], items.map { |item| item["status"] },
      "the failure, then the fact — a decided row never rests at the stage"
    assert_nil items[-2]["approval"]
    assert_equal "human", items.last.dig("approval", "origin")
    assert_equal @human.public_id, items.last.dig("approval", "decided_by")

    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)
    agent_run.reload
    assert_nil agent_run.attention_reason, "the announcement clears with the row"
    assert_equal "running", agent_run.status
    assert_equal "running", node(agent_run, "r1").status, "the absorb fan continues"
    pairing = AgentRuns::RoundReplay::Pairing
    assert_equal "#{pairing::ERROR_OPEN}#{pairing::ERROR_KEY_REASONS.fetch("approval_denied")} " \
      "(approval_denied) use ls#{pairing::ERROR_CLOSE}", paired_results(agent_run, "r1").fetch("call_read")
  end

  test "deny without a reason carries no detail, and by the agent application reads origin agent" do
    agent_run, call = park!
    assert_predicate deny(agent_run, call.node_key, acting_user: @agent), :accepted?
    call.reload
    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_nil call.error_detail
    assert_equal ["agent", @agent.id], call.values_at(:approval_origin, :approved_by_user_id)
    task = AgentAPI::AgentRunPresenter.task(call)
    assert_equal "approval_denied", task.dig(:error, :key)
    assert_nil task.dig(:error, :detail)
    assert_equal "agent", task.dig(:approval, "origin")
  end

  # An authored `halt` step parked by a rule that named its origin: the
  # denial holds the loop, retry re-queues it (the `failed → queued` edge)
  # and it parks again at its next start — the stage is crossed anew.
  test "a denied halt step holds the loop; retry re-queues it to park again at its next start" do
    agent_run = seed(tool("probe", "read_file", "on_failure" => "halt"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_run)
    probe = node(agent_run, "probe")
    assert_equal "needs_approval", probe.status
    assert_equal "author", probe.authored_by

    assert_predicate deny(agent_run, "probe", reason: "not now"), :accepted?
    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)
    agent_run.reload
    assert_equal %w[needs_attention halt_failure], [agent_run.status, agent_run.attention_reason]
    assert_equal ["failed", "approval_denied", "not now"], probe.reload.values_at(:status, :error_key, :error_detail)

    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "probe", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    probe.reload
    assert_equal "queued", probe.status
    assert_equal [nil, nil, nil], probe.values_at(:approval_origin, :approved_by_user_id, :approval_decided_at),
      "the fact was a generation's"
    assert_equal "running", agent_run.reload.status

    perform_enqueued_jobs(only: AgentRuns::ScheduleJob)
    assert_equal "needs_approval", probe.reload.status, "crossed anew, parked anew"
    assert_equal AgentRuns::EvaluateQuiescence::APPROVAL_REASON, agent_run.reload.attention_reason
  end

  # standing pin: a loop-backed loop's verbs read the CONVERSATION's level — a `read` principal is
  # refused before any row is looked at; `full` reaches the row.
  test "a read principal on the hosting conversation has no standing to deny" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, access_default: "read")
    agent_run = create_run_backed_turn(conversation: conversation, acting_user: @agent).agent_run

    assert_equal :not_authorized, deny(agent_run, "nope").outcome
    conversation.conversation_access_entries.create!(user: @human, level: "full")
    assert_equal :task_not_found, deny(agent_run, "nope").outcome, "full reaches the row"
  end

  test "the refusals are approve's: no write standing, a row not resting, an unknown key" do
    agent_run, call = park!
    @workspace.update_column(:state, "archived")
    assert_equal :not_authorized, deny(agent_run, call.node_key).outcome
    @workspace.update_column(:state, "active")
    agent_run.reload
    assert_equal "needs_approval", call.reload.status

    assert_equal :task_not_found, deny(agent_run, "nope").outcome
    assert_equal :not_awaiting_approval, deny(agent_run, "round1").outcome
    assert_predicate deny(agent_run, call.node_key), :accepted?
    assert_equal :not_awaiting_approval, deny(agent_run, call.node_key).outcome
  ensure
    @workspace.update_column(:state, "active")
  end
end
