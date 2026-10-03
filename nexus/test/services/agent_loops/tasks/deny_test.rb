require "test_helper"

# THE APPROVER'S REFUSAL: a row resting at `needs_approval` fails `approval_denied` with the
# person's reason as the detail, the fact stamped; the row's own `on_failure` decides the cascade —
# a model-composed call is `absorb`, so the next round reads the declined sentence and corrects
# itself; an authored `halt` step holds, and a retry parks it again at its next start.
class AgentLoops::Tasks::DenyTest < ActiveJob::TestCase
  include InvocationHarness

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

  def park!
    agent_loop = seed(model("round1", "tools" => [LoopLaneTestHelper::READ_TOOL]), creating_user: @agent,
      approval_mode: "ask")
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @agent))
    clear_enqueued_jobs
    schedule!(agent_loop)
    round = node(agent_loop, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("reading", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_read")
    assert_equal "needs_approval", call.status
    [agent_loop, call]
  end

  def deny(agent_loop, key, reason: nil, acting_user: @human)
    AgentLoops::Tasks::Deny.call(AgentLoops::Tasks::Deny::Command.new(
      agent_loop: agent_loop, task_key: key, acting_user: acting_user, reason: reason
    ))
  end

  def paired_results(agent_loop, key)
    ModelInvocation.find(node(agent_loop, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
      .select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  test "deny with a reason fails the row approval_denied, stamps the fact, and the next round reads the declined sentence" do
    agent_loop, call = park!
    result = deny(agent_loop, call.node_key, reason: "use ls")
    assert_predicate result, :accepted?

    call.reload
    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_equal "use ls", call.error_detail
    assert_equal ["human", @human.id], call.values_at(:approval_origin, :approved_by_user_id)
    assert_not_nil call.approval_decided_at
    assert_not_nil call.completed_at
    assert_nil call.started_at, "nothing was dispatched"
    assert_nil call.failure_resolution, "absorb resolves by derivation"
    assert_equal :resolved, AgentLoops::Graph.settlement_of(call)

    items = agent_loop.conversation_event_items.where(item_type: "task_status")
      .select { |row| row.payload["task_key"] == call.node_key }.map(&:payload)
    assert_equal %w[waiting needs_approval failed failed], items.map { |item| item["status"] },
      "the failure, then the fact — a decided row never rests at the stage"
    assert_nil items[-2]["approval"]
    assert_equal "human", items.last.dig("approval", "origin")
    assert_equal @human.public_id, items.last.dig("approval", "decided_by")

    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)
    agent_loop.reload
    assert_nil agent_loop.attention_reason, "the announcement clears with the row"
    assert_equal "running", agent_loop.status
    assert_equal "running", node(agent_loop, "r1").status, "the absorb fan continues"
    pairing = AgentLoops::RoundReplay::Pairing
    assert_equal "#{pairing::ERROR_OPEN}#{pairing::ERROR_KEY_REASONS.fetch("approval_denied")} " \
      "(approval_denied) use ls#{pairing::ERROR_CLOSE}", paired_results(agent_loop, "r1").fetch("call_read")
  end

  test "deny without a reason carries no detail, and by the agent application reads origin agent" do
    agent_loop, call = park!
    assert_predicate deny(agent_loop, call.node_key, acting_user: @agent), :accepted?
    call.reload
    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_nil call.error_detail
    assert_equal ["agent", @agent.id], call.values_at(:approval_origin, :approved_by_user_id)
    task = AgentAPI::AgentLoopPresenter.task(call)
    assert_equal "approval_denied", task.dig(:error, :key)
    assert_nil task.dig(:error, :detail)
    assert_equal "agent", task.dig(:approval, "origin")
  end

  # An authored `halt` step parked by a rule that named its origin: the
  # denial holds the loop, retry re-queues it (the `failed → queued` edge)
  # and it parks again at its next start — the stage is crossed anew.
  test "a denied halt step holds the loop; retry re-queues it to park again at its next start" do
    agent_loop = seed(tool("probe", "read_file", "on_failure" => "halt"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_loop)
    probe = node(agent_loop, "probe")
    assert_equal "needs_approval", probe.status
    assert_equal "author", probe.authored_by

    assert_predicate deny(agent_loop, "probe", reason: "not now"), :accepted?
    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)
    agent_loop.reload
    assert_equal %w[needs_attention halt_failure], [agent_loop.status, agent_loop.attention_reason]
    assert_equal ["failed", "approval_denied", "not now"], probe.reload.values_at(:status, :error_key, :error_detail)

    retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "probe", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    probe.reload
    assert_equal "queued", probe.status
    assert_equal [nil, nil, nil], probe.values_at(:approval_origin, :approved_by_user_id, :approval_decided_at),
      "the fact was a generation's"
    assert_equal "running", agent_loop.reload.status

    perform_enqueued_jobs(only: AgentLoops::ScheduleJob)
    assert_equal "needs_approval", probe.reload.status, "crossed anew, parked anew"
    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, agent_loop.reload.attention_reason
  end

  # standing pin: a loop-backed loop's verbs read the CONVERSATION's level — a `read` principal is
  # refused before any row is looked at; `full` reaches the row.
  test "a read principal on the hosting conversation has no standing to deny" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, access_default: "read")
    agent_loop = create_loop_backed_turn(conversation: conversation, acting_user: @agent).agent_loop

    assert_equal :not_authorized, deny(agent_loop, "nope").outcome
    conversation.conversation_access_entries.create!(user: @human, level: "full")
    assert_equal :task_not_found, deny(agent_loop, "nope").outcome, "full reaches the row"
  end

  test "the refusals are approve's: no write standing, a row not resting, an unknown key" do
    agent_loop, call = park!
    @workspace.update_column(:state, "archived")
    assert_equal :not_authorized, deny(agent_loop, call.node_key).outcome
    @workspace.update_column(:state, "active")
    agent_loop.reload
    assert_equal "needs_approval", call.reload.status

    assert_equal :task_not_found, deny(agent_loop, "nope").outcome
    assert_equal :not_awaiting_approval, deny(agent_loop, "round1").outcome
    assert_predicate deny(agent_loop, call.node_key), :accepted?
    assert_equal :not_awaiting_approval, deny(agent_loop, call.node_key).outcome
  ensure
    @workspace.update_column(:state, "active")
  end
end
