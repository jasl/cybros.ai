require "test_helper"

class TaskOperationTest < ActiveJob::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  test "a captured observation survives child retry through shared fragments" do
    run = seed(tool("parent", "read_file"), tool("child", "read_file", "on_failure" => "halt"))
    start_loop(run)
    parent = run.tasks.find_by!(node_key: "parent")
    parent_claim = claim(parent)
    assert_predicate Runs::Parks::Settle.call(
      node: parent, claim_token: parent_claim.claim_token, content: "parent"
    ), :applied?
    Runs::ScheduleReady.call(run_id: run.id)
    child = run.tasks.find_by!(node_key: "child")
    child_claim = claim(child)
    assert_predicate Runs::Parks::Settle.call(
      node: child, claim_token: child_claim.claim_token, outcome: "failed", content: "first failure"
    ), :applied?
    operation = operation_for(parent)
    before = ContentFragment.count
    captured = ContentBodies::Replace.call(owner: operation, role: "observation",
      entries: child.output_body.entry_payloads, seal: true)
    assert_predicate captured, :accepted?
    operation.update!(observed_position: 2, observation: { "status" => "failed", "task_key" => child.node_key })

    assert_equal before, ContentFragment.count, "the observation adopts immutable payloads"
    retry_result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: child.node_key, acting_user: @human
    ))
    assert_predicate retry_result, :accepted?, retry_result.outcome.inspect
    assert_nil child.reload.output_body
    assert_equal "first failure", operation.reload.observation_body.effective_text
    assert_equal "failed", operation.observation.fetch("status")
    assert_predicate operation.observation_body, :sealed?
  end

  test "acceptance is immutable and one observation cannot be rewritten" do
    node = seed(tool("parent", "read_file")).tasks.sole
    operation = operation_for(node)
    assert_raises(ActiveRecord::ReadonlyAttributeError) { operation.request = { "other" => true } }
    operation.update!(observed_position: 2, observation: { "status" => "completed" })

    assert_not operation.update(observation: { "status" => "failed" })
    assert_includes operation.errors.details.fetch(:observation).pluck(:error), :readonly
    operation.reload
    assert_not operation.update(observed_position: nil, observation: nil)
    assert_includes operation.errors.details.fetch(:observed_position).pluck(:error), :readonly
  end

  test "task deletion collects its operation bodies without deleting shared fragments" do
    node = seed(tool("parent", "read_file")).tasks.sole
    operation = operation_for(node)
    body = ContentBodies::Replace.call(owner: operation, role: "observation",
      entries: [{ "text" => "captured" }], seal: true).body
    fragment = body.content_body_entries.sole.content_fragment

    Runs::Reap.destroy_aggregate(Run.find(node.run_id))

    assert_not TaskOperation.exists?(operation.id)
    assert_not ContentBody.exists?(body.id)
    assert ContentFragment.exists?(fragment.id)
  end

  private

    def operation_for(node)
      node.task_operations.create!(operation_key: "op-1", kind: "tool", request_digest: "a" * 64,
        request: { "name" => "read_file" }, response: { "task_keys" => ["child"] }, position: 1)
    end

    def start_loop(run)
      assert_predicate Runs::Start.call(Runs::Start::Command.new(
        run: run, acting_user: @human
      )), :accepted?
      Runs::ScheduleReady.call(run_id: run.id)
      clear_enqueued_jobs
    end

    def claim(node)
      outcome = Executors::Claim.call(Executors::Claim::Command.new(
        run: node.run, task_key: node.node_key, executor: suite_runner
      ))
      assert_predicate outcome, :accepted?
      node.reload
    end
end
