require "test_helper"

# Physical reclamation: the one sanctioned path through the graph's
# RESTRICT guards, and the fences that keep it from running while any
# writer could still arrive.
class Runs::ReapTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def create_loop! = seed(model("a"), model("b", "prompt" => "q"), idempotency_key: SecureRandom.uuid)

  def condemn!(run, at: (Run::RETENTION_PERIOD + 1.day).ago)
    run.update!(status: "completed", tombstoned_at: at)
  end

  test "an aged tombstone takes its whole aggregate with it" do
    run = create_loop!
    Event::Append.call(
      host: run,
      items: [{ type: "turn_status", payload: { "run_status" => "completed" } }]
    )
    node_ids = run.tasks.pluck(:id)
    condemn!(run)

    result = Runs::Reap.call(batch: 10)

    assert_equal 1, result[:reaped]
    assert_nil Run.find_by(id: run.id)
    assert_equal 0, Task.where(id: node_ids).count
    assert_equal 0, RunEdge.where(run_id: run.id).count
    assert_equal 0, EventItem.where(host: run).count
    assert_equal 0, RunCreateReceipt.where(run_id: run.id).count
    assert_equal 0, ContentBody.where(task_id: node_ids).count,
      "each task took its bodies with it"
  end

  test "a fresh tombstone and a live loop are both left standing" do
    fresh = create_loop!
    fresh.update!(status: "completed", tombstoned_at: 1.day.ago)
    live = create_loop!

    result = Runs::Reap.call(batch: 10)

    assert_equal 0, result[:reaped]
    assert_not_nil Run.find_by(id: fresh.id)
    assert_not_nil Run.find_by(id: live.id)
  end

  test "nonterminal step work fences reclamation" do
    run = create_loop!
    condemn!(run)
    ModelInvocation.create!(
      run: run, creating_user: @human,
      internal_creation_key: "task:#{run.tasks.first.id}:0",
      provider_id: "dev", model_ref: "mock-text",
      request_options: {}, admission_deadline_seconds: 60
    )

    assert_equal 0, Runs::Reap.call(batch: 10)[:reaped],
      "a result writer must never find its aggregate vanished"

    ModelInvocation.where(run_id: run.id)
      .update_all(status: "completed", terminal_at: Time.current)
    assert_equal 1, Runs::Reap.call(batch: 10)[:reaped]
    assert_equal 0, ModelInvocation.where(run_id: run.id).count,
      "settled step evidence drains with the loop"
  end

  test "tombstone refuses a live loop and is idempotent once accepted" do
    run = create_loop!
    run.update!(status: "running")
    assert_equal :run_busy,
      Runs::Tombstone.call(run: run).outcome

    run.update!(status: "canceled")
    assert_predicate Runs::Tombstone.call(run: run), :accepted?
    assert_equal :already_tombstoned,
      Runs::Tombstone.call(run: run).outcome
  end

  test "expired receipts reap without touching the loops they described" do
    run = create_loop!
    RunCreateReceipt.where(run_id: run.id)
      .update_all(created_at: 2.days.ago)
    RunAppendReceipt.where(run_id: run.id)
      .update_all(created_at: 2.days.ago)

    RunCreateReceipts::ReapJob.perform_now
    RunAppendReceipts::ReapJob.perform_now

    assert_equal 0, RunCreateReceipt.where(run_id: run.id).count
    assert_equal 0, RunAppendReceipt.where(run_id: run.id).count
    assert_not_nil Run.find_by(id: run.id)
    assert_equal 2, run.tasks.count
  end
end
