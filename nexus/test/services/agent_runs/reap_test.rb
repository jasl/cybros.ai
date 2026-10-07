require "test_helper"

# Physical reclamation: the one sanctioned path through the graph's
# RESTRICT guards, and the fences that keep it from running while any
# writer could still arrive.
class AgentRuns::ReapTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def create_loop! = seed(model("a"), model("b", "prompt" => "q"), idempotency_key: SecureRandom.uuid)

  def condemn!(agent_run, at: (AgentRun::RETENTION_PERIOD + 1.day).ago)
    agent_run.update!(status: "completed", tombstoned_at: at)
  end

  test "an aged tombstone takes its whole aggregate with it" do
    agent_run = create_loop!
    ConversationEvent::Append.call(
      host: agent_run,
      items: [{ type: "turn_status", payload: { "run_status" => "completed" } }]
    )
    node_ids = agent_run.agent_run_tasks.pluck(:id)
    condemn!(agent_run)

    result = AgentRuns::Reap.call(batch: 10)

    assert_equal 1, result[:reaped]
    assert_nil AgentRun.find_by(id: agent_run.id)
    assert_equal 0, AgentRunTask.where(id: node_ids).count
    assert_equal 0, AgentRunEdge.where(agent_run_id: agent_run.id).count
    assert_equal 0, ConversationEventItem.where(host: agent_run).count
    assert_equal 0, AgentRunCreateReceipt.where(agent_run_id: agent_run.id).count
    assert_equal 0, ContentBody.where(agent_run_task_id: node_ids).count,
      "each task took its bodies with it"
  end

  test "a fresh tombstone and a live loop are both left standing" do
    fresh = create_loop!
    fresh.update!(status: "completed", tombstoned_at: 1.day.ago)
    live = create_loop!

    result = AgentRuns::Reap.call(batch: 10)

    assert_equal 0, result[:reaped]
    assert_not_nil AgentRun.find_by(id: fresh.id)
    assert_not_nil AgentRun.find_by(id: live.id)
  end

  test "nonterminal step work fences reclamation" do
    agent_run = create_loop!
    condemn!(agent_run)
    ModelInvocation.create!(
      agent_run: agent_run, creating_user: @human,
      internal_creation_key: "agent_run_task:#{agent_run.agent_run_tasks.first.id}:0",
      provider_id: "dev", model_ref: "mock-text",
      request_options: {}, admission_deadline_seconds: 60
    )

    assert_equal 0, AgentRuns::Reap.call(batch: 10)[:reaped],
      "a result writer must never find its aggregate vanished"

    ModelInvocation.where(agent_run_id: agent_run.id)
      .update_all(status: "completed", terminal_at: Time.current)
    assert_equal 1, AgentRuns::Reap.call(batch: 10)[:reaped]
    assert_equal 0, ModelInvocation.where(agent_run_id: agent_run.id).count,
      "settled step evidence drains with the loop"
  end

  test "tombstone refuses a live loop and is idempotent once accepted" do
    agent_run = create_loop!
    agent_run.update!(status: "running")
    assert_equal :run_busy,
      AgentRuns::Tombstone.call(agent_run: agent_run).outcome

    agent_run.update!(status: "canceled")
    assert_predicate AgentRuns::Tombstone.call(agent_run: agent_run), :accepted?
    assert_equal :already_tombstoned,
      AgentRuns::Tombstone.call(agent_run: agent_run).outcome
  end

  test "expired receipts reap without touching the loops they described" do
    agent_run = create_loop!
    AgentRunCreateReceipt.where(agent_run_id: agent_run.id)
      .update_all(created_at: 2.days.ago)
    AgentRunAppendReceipt.where(agent_run_id: agent_run.id)
      .update_all(created_at: 2.days.ago)

    AgentRunCreateReceipts::ReapJob.perform_now
    AgentRunAppendReceipts::ReapJob.perform_now

    assert_equal 0, AgentRunCreateReceipt.where(agent_run_id: agent_run.id).count
    assert_equal 0, AgentRunAppendReceipt.where(agent_run_id: agent_run.id).count
    assert_not_nil AgentRun.find_by(id: agent_run.id)
    assert_equal 2, agent_run.agent_run_tasks.count
  end
end
