require "test_helper"

# THE WORLD, DERIVED: one windowed query over the rows the kernel already keeps, and a fact that
# carries the runner's own record verbatim — the kernel neither compares nor reads it.
class AgentRuns::RunnerEffectsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  # A settled loop-backed turn per loop, the active pointer released so
  # the next one may stand above it.
  def loop!(position: nil)
    seam = create_run_backed_turn(conversation: @conversation.reload, acting_user: @human, position: position,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    @conversation.reload.update!(active_turn: nil)
    seam.agent_run
  end

  test "a claimed runner write is touched: the loop, the claimant, the runner's record verbatim" do
    agent_run = loop!
    row = runner_tool_row(agent_run, "r1t0", claimed_by: "01900000-0000-7000-8000-0000000000e1",
      metadata: { "checkpoint" => { "hash" => "abc", "store" => "s1" } })

    facts = AgentRuns::RunnerEffects.first_writes([agent_run.id])
    assert_equal [agent_run.id], facts.keys
    assert_equal row.id, facts.fetch(agent_run.id).sole.id
    assert_equal(
      { status: "touched", runners: [{ run_public_id: agent_run.public_id, task_key: "r1t0",
        runner_executor_public_id: "01900000-0000-7000-8000-0000000000e1", checkpoint: { "hash" => "abc", "store" => "s1" } }] },
      AgentRuns::RunnerEffects.fact(facts.fetch(agent_run.id))
    )
  end

  test "an unclaimed write, a runner read and a kernel row are untouched" do
    unclaimed = loop!
    runner_tool_row(unclaimed, "r1t0", claimed: false)
    read = loop!(position: 1)
    runner_tool_row(read, "r1t0", kind: "read_only", tool_name: "read")
    kernel = loop!(position: 2)
    runner_tool_row(kernel, "r1t0", role: nil, tool_name: "memory_write")

    facts = AgentRuns::RunnerEffects.first_writes([unclaimed.id, read.id, kernel.id])
    assert_empty facts, "nothing a runner claimed as a write"
    assert_equal({ status: "untouched", runners: [] }, AgentRuns::RunnerEffects.fact(facts[unclaimed.id]))
  end

  test "the first claimed write per loop, across loops, in one statement" do
    first = loop!
    runner_id = SecureRandom.uuid
    first_write = runner_tool_row(first, "r1t0", claimed_by: runner_id)
    runner_tool_row(first, "r2t0", claimed_by: runner_id)
    second = loop!(position: 1)
    runner_tool_row(second, "r1t0", kind: "read_only")
    second_write = runner_tool_row(second, "r2t0", claimed_by: runner_id)
    runner_tool_row(second, "r3t0", claimed_by: runner_id)

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    facts = AgentRuns::RunnerEffects.first_writes([first.id, second.id])
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_equal 1, statements.length, "ONE windowed query for the page's loops: #{statements}"
    assert_equal({ first.id => first_write.id, second.id => second_write.id }, facts.transform_values { |rows| rows.sole.id })
    assert_equal({}, AgentRuns::RunnerEffects.first_writes([]), "no loops, no query")
  end

  test "the fact carries any value under `checkpoint` verbatim, and none when the key is absent" do
    agent_run = loop!
    values = {
      "r1t0" => { "checkpoint" => { "hash" => "h1", "store" => "s1", "outside" => ["/tmp/x"] } },
      "r2t0" => { "checkpoint" => { "skipped" => "tree_too_large", "bytes" => 1, "files" => 2 } },
      "r3t0" => { "checkpoint" => "c1" },
      "r4t0" => { "other" => "value" },
      "r5t0" => :none,
      "r6t0" => { "checkpoint" => nil },
    }
    rows = values.to_h { |key, metadata| [key, runner_tool_row(agent_run, key, metadata: metadata)] }
    by_key = AgentRuns::RunnerEffects.rows(AgentRunTask.where(id: rows.values.map(&:id))).index_by(&:node_key)

    assert_equal({ "hash" => "h1", "store" => "s1", "outside" => ["/tmp/x"] },
      AgentRuns::RunnerEffects.fact(by_key.fetch("r1t0")).fetch(:runners).first.fetch(:checkpoint))
    assert_equal({ "skipped" => "tree_too_large", "bytes" => 1, "files" => 2 },
      AgentRuns::RunnerEffects.fact(by_key.fetch("r2t0")).fetch(:runners).first.fetch(:checkpoint))
    assert_equal "c1", AgentRuns::RunnerEffects.fact(by_key.fetch("r3t0")).fetch(:runners).first.fetch(:checkpoint),
      "a placeholder rides as stored: the kernel reads nothing inside the value"
    assert_not AgentRuns::RunnerEffects.fact(by_key.fetch("r4t0")).fetch(:runners).sole.key?(:checkpoint), "no key, no member"
    assert_not AgentRuns::RunnerEffects.fact(by_key.fetch("r5t0")).fetch(:runners).sole.key?(:checkpoint), "no metadata, no member"
    assert_nil AgentRuns::RunnerEffects.fact(by_key.fetch("r6t0")).fetch(:runners).sole.fetch(:checkpoint)
    assert_equal %i[status runners], AgentRuns::RunnerEffects.fact(by_key.fetch("r5t0")).keys
  end

  test "each Runner has its own first write and task projections agree with the batched reader" do
    agent_run = loop!
    left = SecureRandom.uuid
    right = SecureRandom.uuid
    first = runner_tool_row(agent_run, "left-first", claimed_by: left, metadata: { "checkpoint" => nil })
    second = runner_tool_row(agent_run, "right-first", claimed_by: right, metadata: { "checkpoint" => "right" })
    runner_tool_row(agent_run, "left-later", claimed_by: left, metadata: { "checkpoint" => "later" })
    first.update_columns(claimed_at: nil, claimed_by_executor_public_id: nil, result_metadata: nil,
      addressed_role: nil, effect_profile: nil)

    rows = AgentRuns::RunnerEffects.first_writes([agent_run.id]).fetch(agent_run.id)
    assert_equal [first.id, second.id], rows.map(&:id)
    fact = AgentRuns::RunnerEffects.fact(rows)
    assert_equal [left, right], fact.fetch(:runners).map { |entry| entry.fetch(:runner_executor_public_id) }
    assert_nil fact.fetch(:runners).first.fetch(:checkpoint)
    assert_equal fact, AgentRuns::RunnerEffects.from_tasks(agent_run.agent_run_tasks.to_a, run_public_id: agent_run.public_id)
    assert_equal({ status: "unavailable", runners: [], reason: "execution_details_pruned" },
      AgentRuns::RunnerEffects.fact(rows, details_pruned_at: Time.current))
  end

  test "collecting an executor retains complete effects and its original Runner identity" do
    executor = TaskExecutor.create!(account: @account, manager: users(:owner), executor_kind: "runner",
      display_name: "Collected", registration_identifier: "collected-effects", assignment_scope: "account_wide",
      status: "revoked")
    agent_run = loop!
    row = runner_tool_row(agent_run, "write", claimed_by: executor.public_id, metadata: { "checkpoint" => "kept" })
    AgentRunTask.where(id: row.id).update_all(target_executor_id: executor.id,
      target_executor_public_id: executor.public_id, claimed_by_executor_id: executor.id)
    capture = row.reload.first_runner_write

    TaskExecutor.reap
    assert_nil TaskExecutor.find_by(id: executor.id)
    assert_nil row.reload.target_executor_id
    assert_nil row.claimed_by_executor_id
    assert_equal executor.public_id, row.target_executor_public_id
    assert_equal capture, row.first_runner_write
    fact = AgentRuns::RunnerEffects.from_tasks([row], run_public_id: agent_run.public_id)
    assert_equal "touched", fact.fetch(:status)
    assert_equal executor.public_id, fact.fetch(:runners).sole.fetch(:runner_executor_public_id)
    assert_equal "kept", fact.fetch(:runners).sole.fetch(:checkpoint)
  end
end
