require "test_helper"

# Physical reclamation: the one sanctioned path through the graph's
# RESTRICT guards, and the fences that keep it from running while any
# writer could still arrive.
class AgentLoops::ReapTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def create_loop! = seed(model("a"), model("b", "prompt" => "q"), idempotency_key: SecureRandom.uuid)

  def condemn!(agent_loop, at: (AgentLoop::RETENTION_PERIOD + 1.day).ago)
    agent_loop.update!(status: "completed", tombstoned_at: at)
  end

  test "an aged tombstone takes its whole aggregate with it" do
    agent_loop = create_loop!
    ConversationEvent::Append.call(
      host: agent_loop,
      items: [{ type: "turn_status", payload: { "loop_status" => "completed" } }]
    )
    node_ids = agent_loop.agent_loop_nodes.pluck(:id)
    condemn!(agent_loop)

    result = AgentLoops::Reap.call(batch: 10)

    assert_equal 1, result[:reaped]
    assert_nil AgentLoop.find_by(id: agent_loop.id)
    assert_equal 0, AgentLoopNode.where(id: node_ids).count
    assert_equal 0, AgentLoopEdge.where(agent_loop_id: agent_loop.id).count
    assert_equal 0, ConversationEventItem.where(host: agent_loop).count
    assert_equal 0, AgentLoopCreateReceipt.where(agent_loop_id: agent_loop.id).count
    assert_equal 0, ContentBody.where(agent_loop_node_id: node_ids).count,
      "each task took its bodies with it"
  end

  test "a fresh tombstone and a live loop are both left standing" do
    fresh = create_loop!
    fresh.update!(status: "completed", tombstoned_at: 1.day.ago)
    live = create_loop!

    result = AgentLoops::Reap.call(batch: 10)

    assert_equal 0, result[:reaped]
    assert_not_nil AgentLoop.find_by(id: fresh.id)
    assert_not_nil AgentLoop.find_by(id: live.id)
  end

  test "nonterminal step work fences reclamation" do
    agent_loop = create_loop!
    condemn!(agent_loop)
    ModelInvocation.create!(
      agent_loop: agent_loop, creating_user: @human,
      internal_creation_key: "agent_loop_step:#{agent_loop.agent_loop_nodes.first.id}:0",
      provider_id: "dev", model_ref: "mock-text",
      request_options: {}, admission_deadline_seconds: 60
    )

    assert_equal 0, AgentLoops::Reap.call(batch: 10)[:reaped],
      "a result writer must never find its aggregate vanished"

    ModelInvocation.where(agent_loop_id: agent_loop.id)
      .update_all(status: "completed", terminal_at: Time.current)
    assert_equal 1, AgentLoops::Reap.call(batch: 10)[:reaped]
    assert_equal 0, ModelInvocation.where(agent_loop_id: agent_loop.id).count,
      "settled step evidence drains with the loop"
  end

  test "tombstone refuses a live loop and is idempotent once accepted" do
    agent_loop = create_loop!
    agent_loop.update!(status: "running")
    assert_equal :agent_loop_busy,
      AgentLoops::Tombstone.call(agent_loop: agent_loop).outcome

    agent_loop.update!(status: "canceled")
    assert_predicate AgentLoops::Tombstone.call(agent_loop: agent_loop), :accepted?
    assert_equal :already_tombstoned,
      AgentLoops::Tombstone.call(agent_loop: agent_loop).outcome
  end

  test "expired receipts reap without touching the loops they described" do
    agent_loop = create_loop!
    AgentLoopCreateReceipt.where(agent_loop_id: agent_loop.id)
      .update_all(created_at: 2.days.ago)
    AgentLoopAppendReceipt.where(agent_loop_id: agent_loop.id)
      .update_all(created_at: 2.days.ago)

    AgentLoopCreateReceipts::ReapJob.perform_now
    AgentLoopAppendReceipts::ReapJob.perform_now

    assert_equal 0, AgentLoopCreateReceipt.where(agent_loop_id: agent_loop.id).count
    assert_equal 0, AgentLoopAppendReceipt.where(agent_loop_id: agent_loop.id).count
    assert_not_nil AgentLoop.find_by(id: agent_loop.id)
    assert_equal 2, agent_loop.agent_loop_nodes.count
  end
end
