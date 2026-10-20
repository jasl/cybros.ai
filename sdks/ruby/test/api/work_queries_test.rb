require "test_helper"
require_relative "../support/contract_clients"

class ApiWorkQueriesTest < Minitest::Test
  include CybrosAgentTest::ContractClients

  def test_candidate_windows_preserve_the_cursor_even_when_empty
    %w[valid_run_candidates_fixture empty_run_candidates_fixture].each do |name|
      fixture = contract("work.json").fetch(name)
      page = work(fixture).run_candidates(agent_public_id: "agent", after: "cursor")

      assert_equal fixture.fetch("runs").map { |row| row.fetch("public_id") }, page.items.map(&:public_id)
      assert_equal fixture.dig("pagination", "next_after"), page.next_after
      assert_equal "/agent_api/v1/run_candidates", request.fetch(:path)
      assert_equal({ "agent_public_id" => "agent", "after" => "cursor" }, request.fetch(:params))
    end
  end

  def test_global_runs_keep_the_workspace_and_filters
    fixture = contract("work.json").fetch("valid_runs_fixture")
    page = work(fixture).runs(workspace_public_id: "workspace", from: "2026-10-14T00:00:00Z",
      to: "2026-10-15T00:00:00Z", answering_user_public_id: "answerer", agent_public_id: "agent",
      executor_public_id: "executor", kind: "conversation",
      status: %w[running paused], attention: "any", order: "desc", after: "cursor", limit: 10)

    assert_equal fixture.dig("runs", 0, "workspace_public_id"), page.items.first.workspace_public_id
    assert_equal "/agent_api/v1/runs", request.fetch(:path)
    assert_equal({ "workspace_public_id" => "workspace", "from" => "2026-10-14T00:00:00Z",
      "to" => "2026-10-15T00:00:00Z", "answering_user_public_id" => "answerer", "kind" => "conversation",
      "agent_public_id" => "agent", "executor_public_id" => "executor",
      "status" => "running,paused", "attention" => "any", "order" => "desc", "after" => "cursor", "limit" => 10 }, request.fetch(:params))
  end

  def test_workspace_runs_forward_agent_and_executor_resource_filters
    fixture = contract("work.json").fetch("valid_runs_fixture")
    @transport = CybrosAgentTest::FakeTransport.new([[200, {}, fixture]])
    client = CybrosAgent::Client.new(base_url: "http://example.test", credential: "member", transport: @transport)
    client.workspace("workspace").runs.list(agent_public_id: "agent", executor_public_id: "executor")

    assert_equal "/agent_api/v1/workspaces/workspace/runs", request.fetch(:path)
    assert_equal({ "agent_public_id" => "agent", "executor_public_id" => "executor" }, request.fetch(:params))
  end

  def test_attention_keeps_task_projection_and_read_view
    fixture = contract("work.json").fetch("valid_attention_fixture")
    page = work(fixture).attention(workspace_public_id: "workspace", view: "following", after: "cursor", limit: 5)
    item = page.items.first

    assert_equal fixture.dig("items", 0, "task", "key"), item.task.key
    assert_equal fixture.dig("items", 0, "run_public_id"), item.run_public_id
    assert_nil item.conversation_public_id
    assert_equal "/agent_api/v1/attention", request.fetch(:path)
    assert_equal({ "workspace_public_id" => "workspace", "view" => "following", "after" => "cursor", "limit" => 5 }, request.fetch(:params))
  end

  def test_report_keeps_current_period_previous_and_exact_cost
    fixture = contract("work.json").fetch("valid_report_fixture")
    fixture.fetch("report")["agent_public_id"] = "agent"
    report = work(fixture).report(workspace_public_id: "workspace", agent_public_id: "agent", from: "2026-10-14T00:00:00Z",
      to: "2026-10-15T00:00:00Z", unit: "day")

    assert_equal fixture.dig("report", "current", "run_counts", "canceling"), report.current.run_counts.canceling
    assert_equal fixture.dig("report", "totals", "conversation_usage", "cost_amount"), report.totals.conversation_usage.cost_amount
    refute report.totals.conversation_usage.cost_complete
    assert_equal fixture.dig("report", "series", 0, "bucket_start_at"), report.series.first.bucket_start_at
    assert_equal fixture.dig("report", "previous", "totals", "created_runs"), report.previous.totals.created_runs
    assert_equal "agent", report.agent_public_id
    assert_equal "/agent_api/v1/work_report", request.fetch(:path)
    assert_equal "day", request.fetch(:params).fetch("unit")
    assert_equal "agent", request.fetch(:params).fetch("agent_public_id")
  end

  def test_report_requires_cost_evidence_and_keeps_unknown_response_units
    malformed = Marshal.load(Marshal.dump(contract("work.json").fetch("valid_report_fixture")))
    malformed.fetch("report").fetch("totals").fetch("conversation_usage").delete("cost_complete")
    assert_raises(CybrosAgent::Api::MalformedResponse) { work(malformed).report }
    fixture = contract("work.json").fetch("unknown_unit_fixture")
    assert_equal fixture.dig("report", "unit"), work(fixture).report.unit
    assert_nil request.fetch(:params)
  end

  private

    def work(body)
      @transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "member", transport: @transport).work
    end

    def request = @transport.requests.last
end
