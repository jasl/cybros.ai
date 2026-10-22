require "test_helper"

class Runs::FirstRunnerWriteTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  def start_write
    run = seed(tool("write", "write"), tool("tail", "read_file"))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    schedule(run)
    run
  end

  def schedule(run)
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  def claim(run)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: "write", executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    result.value
  end

  def commit(run, token:, metadata:, outcome: "completed")
    Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: "write", executor: suite_runner, claim_token: token,
      content: "done", result_type: nil, outcome: outcome, is_error: false,
      title: nil, metadata: metadata
    ))
  end

  def retry_task(run)
    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run.reload, task_key: "write", acting_user: @human
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    schedule(run)
  end

  test "the first claim captures the immutable Runner and generation atomically" do
    run = start_write
    row = run.tasks.find_by!(node_key: "write")
    assert_nil row.first_runner_write
    claimed = claim(run)
    assert_equal({
      "execution_generation" => claimed.execution_generation,
      "runner_executor_public_id" => claimed.target_executor_public_id,
      "claimed_at" => claimed.claimed_at.utc.iso8601(6),
    }, claimed.reload.first_runner_write)
    assert_equal suite_runner.public_id, claimed.first_runner_write.fetch("runner_executor_public_id")
    assert_not claimed.first_runner_write.key?("checkpoint")
  end

  test "an accepted failed result retains a null checkpoint and retry cannot replace the first capture" do
    run = start_write
    row = claim(run)
    stale_token = row.claim_token
    assert_predicate commit(run, token: stale_token, metadata: { "checkpoint" => nil }, outcome: "failed"), :applied?
    capture = row.reload.first_runner_write
    assert_nil capture.fetch("checkpoint")

    retry_task(run)
    assert_equal capture, row.reload.first_runner_write
    retried = claim(run)
    assert_operator retried.execution_generation, :>, capture.fetch("execution_generation")
    assert_equal :stale_claim, commit(run, token: stale_token, metadata: { "checkpoint" => "stale" }).outcome
    assert_predicate commit(run, token: retried.claim_token, metadata: { "checkpoint" => "new" }), :applied?
    assert_equal capture, row.reload.first_runner_write
  end

  test "retry cannot fill a checkpoint absent from the captured generation" do
    run = start_write
    row = claim(run)
    assert_predicate commit(run, token: row.claim_token, metadata: nil, outcome: "failed"), :applied?
    capture = row.reload.first_runner_write
    retry_task(run)
    retried = claim(run)
    assert_predicate commit(run, token: retried.claim_token, metadata: { "checkpoint" => "later" }), :applied?
    assert_equal capture, row.reload.first_runner_write
    assert_not row.first_runner_write.key?("checkpoint")
  end

  test "a refused or expired result cannot add checkpoint evidence" do
    run = start_write
    row = claim(run)
    token = row.claim_token
    capture = row.first_runner_write
    assert_equal :stale_claim, commit(run, token: "stale", metadata: { "checkpoint" => "stale" }).outcome
    assert_equal :metadata_too_large, commit(run, token: token,
      metadata: { "checkpoint" => "x" * Nexus::SizeBounds.fetch(:envelope_bound) }).outcome
    assert_equal capture, row.reload.first_runner_write

    row.update_columns(await_started_at: 2.hours.ago)
    assert_predicate commit(run, token: token, metadata: { "checkpoint" => "late" }), :applied?
    assert_equal "uncertain", row.reload.status
    assert_equal capture, row.first_runner_write
  end

  test "a checkpoint at the metadata limit still fits its retained capture wrapper" do
    run = start_write
    row = claim(run)
    checkpoint = "x" * (Nexus::SizeBounds.fetch(:envelope_bound) - '{"checkpoint":""}'.bytesize)
    assert_predicate commit(run, token: row.claim_token, metadata: { "checkpoint" => checkpoint }), :applied?
    assert_equal checkpoint, row.reload.first_runner_write.fetch("checkpoint")
  end

  test "a withdrawn capability refuses the claim before any first write is captured" do
    run = start_write
    assert_predicate suite_runner.announce(services: { suite_runner.executor_kind => { "tools" => [] } }), :accepted?
    result = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: "write", executor: suite_runner
    ))
    assert_equal :tool_not_served, result.outcome
    row = run.tasks.find_by!(node_key: "write")
    assert_nil row.first_runner_write
    assert_nil row.claimed_at
  end
end
