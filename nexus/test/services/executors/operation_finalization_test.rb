require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Executors::OperationFinalizationTest < ActiveJob::TestCase
  include LockOrderTestHelper
  include RowLockTestHelper

  uses_transaction :test_concurrent_final_retries_publish_one_body_and_replay_the_winner
  uses_transaction :test_first_operation_acceptance_and_plain_tool_finalization_have_one_winner

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @runner = suite_runner
    @runner.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS + [{
      "name" => "program", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }])
  end

  test "success waits for the accepted child's observation and then publishes one immutable final" do
    parent = start_program
    child = accepted_child(parent, "read")
    assert_equal :pending_children, commit(parent).outcome
    assert_nil parent.reload.output_body

    finish(child, structured_content: false)
    assert_equal :pending_children, commit(parent).outcome, "completion alone is not consumption"
    assert_ladder_order("observe operation child") { observe(parent) }

    assert_ladder_order("finalize operation owner") do
      assert_predicate commit(parent, content: nil, structured_content: false), :applied?
    end
    assert_equal [{ "structured" => false }], parent.reload.output_body.entry_payloads
    assert parent.committed_result_digest
    assert_equal :idle, commit(parent, content: nil, structured_content: false).outcome
    assert_equal :final_result_conflict,
      commit(parent, content: nil, structured_content: nil, structured_content_present: true).outcome
    assert_equal 1, parent.content_bodies.where(role: "output").count
  end

  test "explicit null survives finalization and exact replay after the deadline still proves the final claim" do
    parent = start_program
    finish(accepted_child(parent, "read"))
    observe(parent)
    result = commit(parent, content: nil, structured_content: nil, structured_content_present: true)
    assert_predicate result, :applied?
    assert_equal [{ "structured" => nil }], parent.reload.output_body.entry_payloads

    travel 1.hour do
      assert_equal :idle,
        commit(parent, content: nil, structured_content: nil, structured_content_present: true).outcome
      assert_equal :final_result_conflict, commit(parent, content: nil).outcome
      assert_equal :stale_claim,
        commit(parent, token: "old-token", content: nil, structured_content: nil, structured_content_present: true).outcome
    end
  end

  test "an active operation owner can publish its final while a graceful stop drains" do
    parent = start_program
    finish(accepted_child(parent, "read"))
    observe(parent)
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: parent.agent_run, acting_user: @human, force: false
    )), :accepted?
    assert_equal "canceling", parent.agent_run.reload.status
    assert_equal "dispatched", parent.reload.status

    assert_predicate commit(parent, content: "finished while draining"), :applied?

    assert_equal "completed", parent.reload.status
    assert_equal "finished while draining", parent.output_body.effective_text
    AgentRuns::ScheduleReady.call(agent_run_id: parent.agent_run_id)
    assert_equal "canceled", parent.agent_run.reload.status
  end

  test "an active operation owner can publish its final while graceful pause holds scheduling" do
    parent = start_program
    finish(accepted_child(parent, "read"))
    observe(parent)
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: parent.agent_run, acting_user: @human
    )), :accepted?
    assert_equal "paused", parent.agent_run.reload.status
    assert_equal "dispatched", parent.reload.status

    assert_predicate commit(parent, content: "finished while paused"), :applied?

    assert_equal "completed", parent.reload.status
    assert_equal "finished while paused", parent.output_body.effective_text
    AgentRuns::ScheduleReady.call(agent_run_id: parent.agent_run_id)
    assert_equal "paused", parent.agent_run.reload.status
  end

  test "an accepted refusal must be observed before a successful final" do
    parent = start_program
    response = submit(parent, "refusal", { "kind" => "tool", "name" => "not_declared", "input" => {} })
    assert_equal "unknown_tool_name", response.dig("operation", "refusal", "code")
    assert_equal :pending_children, commit(parent).outcome

    observe(parent)

    assert_predicate commit(parent), :applied?
  end

  test "failure cancels attached children and preserves an explicit background launch" do
    parent = start_program
    attached = accepted_child(parent, "attached")
    background = background_child(parent, "background")

    assert_predicate commit(parent, outcome: "failed", content: "program failed"), :applied?

    assert_equal "failed", parent.reload.status
    assert_equal "canceled", attached.reload.status
    assert_equal "queued", background.reload.status
    assert_equal :idle, commit(parent, outcome: "failed", content: "program failed").outcome
  end

  test "an unstorable failure closes the parent and its attached children without accepting a final digest" do
    parent = start_program
    child = accepted_child(parent, "attached")

    result = commit(parent, outcome: "failed", content: "invalid\u0000result")

    assert_equal :result_unstorable, result.outcome
    assert_predicate result, :moved?
    assert_equal "failed", parent.reload.status
    assert_equal "result_unstorable", parent.error_key
    assert_nil parent.committed_result_digest
    assert_nil parent.output_body
    assert_equal "canceled", child.reload.status
  end

  test "concurrent final retries publish one body and replay the winner" do
    parent = start_program
    finish(accepted_child(parent, "read"))
    observe(parent)
    held = hold_row_lock(AgentRun, parent.agent_run_id)
    first = start_database_call { commit(parent, content: "one final") }
    second = start_database_call { commit(parent, content: "one final") }
    wait_until_waiting_on_lock(first.pid, second.pid)
    release_row_lock(held)
    held = nil

    assert_equal %i[applied idle], [finish_database_call(first).outcome, finish_database_call(second).outcome].sort
    assert_equal "completed", parent.reload.status
    assert_equal "one final", parent.output_body.effective_text
    assert_equal 1, parent.content_bodies.where(role: "output").count
    assert parent.committed_result_digest
  ensure
    release_row_lock(held) if held
    first&.thread&.join(5)
    second&.thread&.join(5)
    AgentRuns::Reap.destroy_aggregate(AgentRun.find(parent.agent_run_id)) if parent
  end

  test "first operation acceptance and plain tool finalization have one winner" do
    parent = start_program
    held = hold_row_lock(AgentRun, parent.agent_run_id)
    operation = start_database_call do
      Executors::TaskOperations::Submit.new(access: access(parent), key: "read",
        request: { "kind" => "tool", "name" => "read_file", "input" => {} }).call
    end
    final = start_database_call { commit(parent) }
    wait_until_waiting_on_lock(operation.pid, final.pid)
    release_row_lock(held)
    held = nil

    submitted = finish_database_call(operation)
    settled = finish_database_call(final)
    if submitted.accepted?
      assert_equal :pending_children, settled.outcome
      assert_equal "dispatched", parent.reload.status
      assert_equal 1, parent.task_operations.count
      assert_nil parent.output_body
    else
      assert_includes %i[execution_stopped task_not_running], submitted.outcome
      assert_predicate settled, :applied?
      assert_equal "completed", parent.reload.status
      assert_empty parent.task_operations
    end
  ensure
    release_row_lock(held) if held
    operation&.thread&.join(5)
    final&.thread&.join(5)
    AgentRuns::Reap.destroy_aggregate(AgentRun.find(parent.agent_run_id)) if parent
  end

  test "an explicit transfer permits success without inventing an observation for unfinished work" do
    parent = start_program
    child = accepted_child(parent, "attached")
    submit(parent, "release", { "kind" => "background", "input" => {
      "operation_key" => "attached", "lifetime" => "conversation", "wake" => "passive",
    } })

    assert_predicate commit(parent), :applied?

    assert_equal "queued", child.reload.status
    assert_nil parent.task_operations.find_by!(operation_key: "attached").observed_position
    assert_predicate child, :detached?
  end

  test "a parent's failure retains a nested operation owner's explicitly released work" do
    parent = start_program
    nested = accepted_child(parent, "nested", name: "program")
    nested = claim(nested)
    background = background_child(nested, "background")

    assert_predicate commit(parent, outcome: "failed"), :applied?

    assert_equal "canceled", nested.reload.status
    assert_equal "queued", background.reload.status
  end

  test "claim expiry cancels attached children through the same failure owner" do
    parent = start_program(timeout_ms: 30_000)
    attached = accepted_child(parent, "attached")
    background = background_child(parent, "background")

    DatabaseClock.stub(:now, parent.deadline_at + 1.second) do
      AgentRuns::Parks::TimeoutSweep.call
    end

    assert_equal "timed_out", parent.reload.status
    assert_nil parent.committed_result_digest
    assert_equal "canceled", attached.reload.status
    assert_equal "queued", background.reload.status
  end

  test "final output may retain another executor's observed capture but no adjacent capture" do
    provider = connect_provider(identifier: "media-provider", tools: ["net_fetch"])
    parent = start_program
    child = accepted_child(parent, "capture", name: "net_fetch")
    capture = staged(provider, "observed")
    finish(child, executor: provider, content: [link(capture)])
    observe(parent)
    unrelated = staged(provider, "unobserved")

    assert_equal :unknown_result_upload, commit(parent, content: [link(unrelated)]).outcome
    assert_nil parent.reload.output_body
    assert_ladder_order("finalize observed capture") do
      assert_predicate commit(parent, content: [link(capture)]), :applied?
    end

    assert_equal [capture.id], parent.reload.output_body.content_uploads.pluck(:id)
    assert_equal [link(capture)], AgentRuns::TaskResultProjection.content_blocks(parent.output_body.entry_payloads)
      .map(&:stringify_keys)
    assert capture.readable_by?(@human)
    assert_not ContentUpload.unbound.exists?(id: capture.id)
    assert ContentUpload.unbound.exists?(id: unrelated.id)
  end

  private

    def start_program(timeout_ms: 90_000)
      tools = fixture_runner_declarations([RunLaneTestHelper::READ_TOOL]) +
        [declaration("program").merge("route" => { "kind" => "runner", "runner_executor_public_id" => @runner.public_id, "tool_name" => "program" }), declaration("net_fetch")]
      agent_run = seed(tool("program", "program", "route" => { "kind" => "runner" }, "timeout_ms" => timeout_ms,
        "model_defaults" => { "tools" => tools, "model" => { "model" => "dev/mock-text" } }))
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
      claim(agent_run.agent_run_tasks.sole)
    end

    def declaration(name)
      { "type" => "function", "function" => { "name" => name, "description" => "test tool",
        "parameters" => { "type" => "object" } } }
    end

    def claim(node, executor: @runner)
      AgentRuns::ScheduleReady.call(agent_run_id: node.agent_run_id)
      result = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: node.agent_run, task_key: node.node_key, executor: executor
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def access(node)
      Executors::TaskOperations::Access.new(agent_run: node.agent_run, task_key: node.node_key,
        executor: @runner, claim_token: node.claim_token)
    end

    def submit(node, key, request)
      result = Executors::TaskOperations::Submit.new(access: access(node), key: key, request: request).call
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def accepted_child(parent, key, name: "read_file")
      response = submit(parent, key, { "kind" => "tool", "name" => name, "input" => {} })
      assert_nil response.dig("operation", "refusal"), response.inspect
      child_key = response.dig("operation", "receipt", "task_keys").sole
      parent.agent_run.agent_run_tasks.find_by!(node_key: child_key)
    end

    def background_child(parent, key)
      response = submit(parent, key, { "kind" => "background", "input" => {
        "steps" => [{ "tool" => { "name" => "read_file", "input" => {} } }], "wake" => "passive",
      } })
      assert_nil response.dig("operation", "refusal"), response.inspect
      child_key = response.dig("operation", "receipt", "task_keys").sole
      parent.agent_run.agent_run_tasks.find_by!(node_key: child_key)
    end

    def finish(child, executor: @runner, content: "child", structured_content: nil)
      child = claim(child, executor: executor)
      assert_predicate commit(child, executor: executor, content: content, structured_content: structured_content), :applied?
      child
    end

    def observe(parent)
      result = Executors::TaskOperations::Observe.new(access: access(parent),
        after: Executors::TaskOperations::Trace.position(parent)).call
      assert_predicate result, :accepted?, result.outcome.inspect
      assert result.value.fetch("observation")
      result.value
    end

    def commit(node, executor: @runner, token: node.claim_token, **overrides)
      Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: node.agent_run, task_key: node.node_key, executor: executor, claim_token: token,
        **{ content: "done", structured_content: nil, result_type: nil, outcome: "completed",
            is_error: false, title: nil, metadata: nil }.merge(overrides)
      ))
    end

    def staged(executor, words)
      executor.account.content_uploads.create!(creating_executor: executor,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(words), filename: "result.txt",
          content_type: "text/plain"))
    end

    def link(upload)
      { "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}", "name" => "result.txt" }
    end
end
