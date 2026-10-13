require "test_helper"

class AgentRuns::FirstRunnerWriteTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  def start_write
    agent_run = seed(tool("write", "write"), tool("tail", "read_file"))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    schedule(agent_run)
    agent_run
  end

  def schedule(agent_run)
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def claim(agent_run)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "write", executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    result.value
  end

  def commit(agent_run, token:, metadata:, outcome: "completed")
    Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: "write", executor: suite_runner, claim_token: token,
      content: "done", result_type: nil, outcome: outcome, is_error: false,
      title: nil, metadata: metadata
    ))
  end

  def retry_task(agent_run)
    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run.reload, task_key: "write", acting_user: @human
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    schedule(agent_run)
  end

  test "the first claim captures the immutable Runner and generation atomically" do
    agent_run = start_write
    row = agent_run.agent_run_tasks.find_by!(node_key: "write")
    assert_nil row.first_runner_write
    claimed = claim(agent_run)
    assert_equal({
      "execution_generation" => claimed.execution_generation,
      "runner_executor_public_id" => claimed.target_executor_public_id,
      "claimed_at" => claimed.claimed_at.utc.iso8601(6),
    }, claimed.reload.first_runner_write)
    assert_equal suite_runner.public_id, claimed.first_runner_write.fetch("runner_executor_public_id")
    assert_not claimed.first_runner_write.key?("checkpoint")
  end

  test "an accepted failed result retains a null checkpoint and retry cannot replace the first capture" do
    agent_run = start_write
    row = claim(agent_run)
    stale_token = row.claim_token
    assert_predicate commit(agent_run, token: stale_token, metadata: { "checkpoint" => nil }, outcome: "failed"), :applied?
    capture = row.reload.first_runner_write
    assert_nil capture.fetch("checkpoint")

    retry_task(agent_run)
    assert_equal capture, row.reload.first_runner_write
    retried = claim(agent_run)
    assert_operator retried.execution_generation, :>, capture.fetch("execution_generation")
    assert_equal :stale_claim, commit(agent_run, token: stale_token, metadata: { "checkpoint" => "stale" }).outcome
    assert_predicate commit(agent_run, token: retried.claim_token, metadata: { "checkpoint" => "new" }), :applied?
    assert_equal capture, row.reload.first_runner_write
  end

  test "retry cannot fill a checkpoint absent from the captured generation" do
    agent_run = start_write
    row = claim(agent_run)
    assert_predicate commit(agent_run, token: row.claim_token, metadata: nil, outcome: "failed"), :applied?
    capture = row.reload.first_runner_write
    retry_task(agent_run)
    retried = claim(agent_run)
    assert_predicate commit(agent_run, token: retried.claim_token, metadata: { "checkpoint" => "later" }), :applied?
    assert_equal capture, row.reload.first_runner_write
    assert_not row.first_runner_write.key?("checkpoint")
  end

  test "a refused or expired result cannot add checkpoint evidence" do
    agent_run = start_write
    row = claim(agent_run)
    token = row.claim_token
    capture = row.first_runner_write
    assert_equal :stale_claim, commit(agent_run, token: "stale", metadata: { "checkpoint" => "stale" }).outcome
    assert_equal :metadata_too_large, commit(agent_run, token: token,
      metadata: { "checkpoint" => "x" * Nexus::SizeBounds.fetch(:envelope_bound) }).outcome
    assert_equal capture, row.reload.first_runner_write

    row.update_columns(await_started_at: 2.hours.ago)
    assert_predicate commit(agent_run, token: token, metadata: { "checkpoint" => "late" }), :applied?
    assert_equal "uncertain", row.reload.status
    assert_equal capture, row.first_runner_write
  end

  test "a checkpoint at the metadata limit still fits its retained capture wrapper" do
    agent_run = start_write
    row = claim(agent_run)
    checkpoint = "x" * (Nexus::SizeBounds.fetch(:envelope_bound) - '{"checkpoint":""}'.bytesize)
    assert_predicate commit(agent_run, token: row.claim_token, metadata: { "checkpoint" => checkpoint }), :applied?
    assert_equal checkpoint, row.reload.first_runner_write.fetch("checkpoint")
  end

  test "a withdrawn capability refuses the claim before any first write is captured" do
    agent_run = start_write
    assert_predicate suite_runner.announce(tools: []), :accepted?
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "write", executor: suite_runner
    ))
    assert_equal :tool_not_served, result.outcome
    row = agent_run.agent_run_tasks.find_by!(node_key: "write")
    assert_nil row.first_runner_write
    assert_nil row.claimed_at
  end
end
