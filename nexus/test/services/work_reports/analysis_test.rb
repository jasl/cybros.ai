require "test_helper"

class WorkReports::AnalysisTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions
  include ActiveJob::TestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @from = Time.utc(2026, 10, 10)
    @to = @from + 2.days
    @conversation = conversation
  end

  test "model receipt time and filters are independent of the Run creation cohort" do
    first = hosted_run(@conversation, created_at: @from)
    first.update_columns(delivered_at: @from, completed_at: @from + 1.0019)
    second = standalone_run(created_at: @from + 1.hour)
    second.update_columns(delivered_at: @from + 1.hour + 0.2509)
    pruned = hosted_run(@conversation, created_at: @from + 2.hours)
    pruned.update_columns(details_pruned_at: Time.current, completed_at: @from + 2.hours + 2)
    old = hosted_run(@conversation, created_at: @from - 1.hour)
    receipt(@conversation, status: "failed", recorded_at: @from + 1.hour, duration_ms: 17)
    receipt(@conversation, recorded_at: @to, total_tokens: 900)
    standalone_run(created_at: @to)

    result = analyze(filters: { "status" => "failed", "provider_id" => "dev" })
    report = result.report
    assert_equal 1, report.model_usage.totals.fetch("request_count")
    assert_equal 17, report.model_usage.latency.duration_ms.p95
    execution = report.execution
    assert_equal 3, execution.run_count
    assert_equal 2, execution.retained_run_count
    assert_equal 1, execution.details_pruned_run_count
    assert_equal 2, execution.delivered_count
    assert_equal 1, execution.undelivered_count
    assert_equal 2, execution.completed_count
    assert_equal 1, execution.uncompleted_count
    assert_equal 2, execution.status_counts.fetch("completed")
    assert_equal 1, execution.status_counts.fetch("running")
    assert_equal({ sample_count: 2, missing_count: 1, p50: 0, p95: 250 }, execution.latency.delivery_ms.to_h)
    assert_equal({ sample_count: 2, missing_count: 1, p50: 1001, p95: 2000 }, execution.latency.completion_ms.to_h)
    assert_equal 3, analyze(filters: { "provider_id" => "no-receipts" }).report.execution.run_count
    assert_equal 0, analyze(filters: { "provider_id" => "no-receipts" }).report.model_usage.totals.fetch("request_count")
    assert_operator old.created_at, :<, @from
  end

  test "tools use current retained tasks and separate error results from failed execution" do
    run = standalone_run(created_at: @from)
    tool(run, "a1", name: "alpha", status: "completed", duration: 0, is_error: true)
    tool(run, "a2", name: "alpha", status: "failed", duration: 0.0109, is_error: true)
    tool(run, "b1", name: "beta", status: "completed", duration: 0.0309)
    tool(run, "b2", name: "beta", status: "queued")
    old = standalone_run(created_at: @from - 1.hour)
    tool(old, "old", name: "old", status: "completed", duration: 100)
    hidden = conversation(creating_user: users(:owner), access_default: "none")
    hidden_run = hosted_run(hidden, created_at: @from)
    tool(hidden_run, "hidden", name: "hidden", status: "completed", duration: 100)

    report = nil
    assert_no_queries_match(/\ASELECT "(?:runs|tasks|usage_records|conversations)"\.\*/) do
      report = analyze(limit: 1).report
    end
    tools = report.execution.tools
    assert_equal 4, tools.task_count
    assert_equal 2, tools.status_counts.fetch("completed")
    assert_equal 1, tools.status_counts.fetch("failed")
    assert_equal 1, tools.error_result_count
    assert_equal({ sample_count: 3, missing_count: 1, p50: 10, p95: 30 }, tools.latency.to_h)
    assert_equal 2, tools.total_group_count
    assert_equal ["alpha"], tools.groups.map(&:tool_name)
    assert_equal 2, tools.other_task_count
    assert_equal 1, tools.groups.first.error_result_count
    assert_equal 0, tools.groups.first.latency.p50
  end

  test "retry clears the old generation's timing and outcome without counting another tool attempt" do
    run = standalone_run(created_at: @from, status: "needs_attention")
    node = tool(run, "retry", name: "retained", status: "failed", duration: 10)
    assert_equal 10000, analyze.report.execution.tools.latency.p95

    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run:, task_key: node.node_key, acting_user: @human
    ))
    assert_predicate result, :accepted?
    tools = analyze.report.execution.tools
    assert_equal 1, tools.task_count
    assert_equal 1, tools.status_counts.fetch("queued")
    assert_equal 0, tools.status_counts.fetch("failed")
    assert_equal 0, tools.latency.sample_count
    assert_equal 1, tools.latency.missing_count
    assert_nil tools.latency.p95
  end

  test "content visibility controls historical receipts and tool names without management bypass" do
    @conversation.update!(access_default: "none")
    run = hosted_run(@conversation, created_at: @from)
    tool(run, "private", name: "private_tool", status: "completed", duration: 1)
    receipt(@conversation, total_tokens: 42)
    admin = analyze(user: users(:owner)).report
    assert_equal 0, admin.model_usage.totals.fetch("request_count")
    assert_equal 0, admin.execution.run_count
    assert_empty admin.execution.tools.groups

    entry = @conversation.conversation_access_entries.create!(user: users(:owner), level: "read")
    admin = analyze(user: users(:owner)).report
    assert_equal 42, admin.model_usage.totals.fetch("total_tokens")
    assert_equal ["private_tool"], admin.execution.tools.groups.map(&:tool_name)
    entry.update!(level: "none")
    assert_equal 0, analyze(user: users(:owner)).report.execution.tools.task_count
    @workspace.update!(access_mode: "private")
    assert_equal 0, analyze.report.model_usage.totals.fetch("request_count")
  end

  test "Agent scope retains trial answerers but consumes only that Agent's attributed receipts" do
    agent = users(:agent)
    hosted_run(@conversation, created_at: @from)
    receipt(@conversation, consumer_user_public_id: @human.public_id, total_tokens: 41)
    receipt(@conversation, consumer_user_public_id: agent.public_id, total_tokens: 17)
    receipt(nil, consumer_user_public_id: agent.public_id, total_tokens: 900)
    standalone_run(created_at: @from, creating_user: agent)

    report = analyze(agent:).report
    assert_equal agent.public_id, report.agent_public_id
    assert_equal 2, report.execution.run_count
    assert_equal 17, report.model_usage.totals.fetch("total_tokens")
    assert_equal 58, analyze.report.model_usage.totals.fetch("total_tokens")
    assert_equal 1, report.model_usage.totals.fetch("request_count")
  end

  test "a Workspace scope restricts both aggregates and empty coverage remains explicit" do
    hosted_run(@conversation, created_at: @from)
    receipt(@conversation)
    report = analyze(workspace: workspaces(:personal)).report
    assert_equal workspaces(:personal).public_id, report.workspace_public_id
    assert_equal 0, report.execution.run_count
    assert_equal 0, report.execution.tools.task_count
    assert_equal 0, report.execution.tools.total_group_count
    assert_nil report.execution.latency.delivery_ms.p50
    assert_equal 0, report.model_usage.totals.fetch("request_count")
  end

  private

    def analyze(**options)
      WorkReports::Analysis.call(user: @human, from: @from, to: @to, **options)
    end

    def conversation(**options)
      Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent), **options)
    end

    def hosted_run(conversation, created_at:)
      seam = create_run_backed_turn(conversation:, acting_user: conversation.creating_user,
        turn_status: "completed", variant_status: "completed", run_status: "completed")
      seam.run.update_columns(created_at:)
      seam.run
    end

    def standalone_run(**options)
      Run.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass", **options)
    end

    def tool(run, key, name:, status:, duration: nil, is_error: false)
      node = run.tasks.create!(node_key: key, type: Tasks::ToolTask.sti_name,
        tool_name: name, tool_input: {}, authored_by: "author", on_failure: "halt")
      node.update_columns(status:, output_summary: { "is_error" => is_error },
        started_at: duration ? @from : nil, completed_at: duration ? @from + duration : nil)
      node
    end

    def receipt(conversation, **options)
      UsageRecord.create!(account: @human.account, idempotency_key: SecureRandom.uuid_v7,
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: users(:agent).public_id, payer_user_public_id: users(:owner).public_id,
        workspace_public_id: conversation&.workspace&.public_id || @workspace.public_id,
        conversation_public_id: conversation&.public_id, provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation", purpose: "task", service_class: "interactive",
        admission_shape: "priced", status: "succeeded", recorded_at: @from + 1.hour, cost_unit: "USD", **options)
    end
end
