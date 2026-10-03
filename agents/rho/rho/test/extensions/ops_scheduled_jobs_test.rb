require "test_helper"
require_relative "../support/ops_harness"

class OpsScheduledJobsTest < Minitest::Test
  include RhoTest::OpsHarness

  class JobsApi < NexusDoubles::FakeAgentApi
    attr_reader :job_writes

    def initialize
      super(workspaces: [{ public_id: "original", name: "Original workspace" }])
      @job_writes = []
      @job = { "public_id" => "job-1", "prompt" => "Report progress", "status" => "completed", "lock_version" => 3,
        "rule" => { "kind" => "once", "run_at" => "2026-10-02T09:00:00Z" },
        "model" => { "model" => "dev/model" }, "last_execution" => execution }
    end

    def execution
      { "child_conversation_public_id" => "child-1", "scheduled_for" => "2026-10-02T09:00:00Z",
        "status" => "running", "created_at" => "2026-10-02T09:00:00Z" }
    end

    def conversation_response(method, path, credential, body, params: nil)
      return super unless credential == NexusDoubles::MEMBER_TOKEN && path.include?("/scheduled_jobs")

      if method == :get
        if path.end_with?("/executions")
          respond(200, { "executions" => [execution], "pagination" => { "next_after" => nil, "last_cursor" => "tail-1" } })
        elsif path.end_with?("/scheduled_jobs")
          respond(200, { "scheduled_jobs" => [@job], "pagination" => { "next_after" => "next-1" } })
        else
          respond(200, { "scheduled_job" => @job })
        end
      else
        @job_writes << [method, path, body]
        respond(path.end_with?("/scheduled_jobs") ? 201 : 200, { "scheduled_job" => @job })
      end
    end
  end

  def test_jobs_routes_share_authenticated_member_plane_without_a_local_host
    daemon = boot
    [[:get, "/conversations/scheduled_jobs?public_id=c-1"],
     [:post, "/conversations/scheduled_jobs/create"]].each do |method, path|
      assert_equal "401", request(daemon, method, path).code
      response = request(daemon, method, path, token: bearer(daemon), body: { public_id: "c-1" })
      assert_equal "409", response.code
      assert_equal "member_plane_unavailable", JSON.parse(response.body).dig("error", "code")
    end
  end

  def test_list_and_execution_reads_preserve_workspace_cursors_and_actual_child_status
    api = JobsApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :get, "/conversations/scheduled_jobs?public_id=c-1&workspace_public_id=original&after=older&limit=7", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body)
    assert_equal "completed", document.dig("scheduled_jobs", 0, "status")
    assert_equal "running", document.dig("scheduled_jobs", 0, "last_execution", "status")
    assert_equal "next-1", document.dig("pagination", "next_after")
    path, credential, params = api.requests.last
    assert_equal "/agent_api/v1/workspaces/original/conversations/c-1/scheduled_jobs", path
    assert_equal NexusDoubles::MEMBER_TOKEN, credential
    assert_equal({ "after" => "older", "limit" => 7 }, params)
    response = request(daemon, :get, "/conversations/scheduled_jobs/executions?public_id=c-1&job_public_id=job-1&after=tail", token: bearer(daemon))
    document = JSON.parse(response.body)
    assert_equal "child-1", document.dig("executions", 0, "child_conversation_public_id")
    assert_equal "tail-1", document.dig("pagination", "last_cursor")
    assert_empty daemon.lineage.runs
  end

  def test_create_update_and_state_commands_forward_only_the_authoring_contract
    api = JobsApi.new
    daemon = member_ready(boot, api)
    body = { public_id: "c-1", workspace_public_id: "original", idempotency_key: "intent-1",
      prompt: "Report progress", rule: { kind: "daily", local_time: "09:00", time_zone: "Asia/Shanghai" },
      model: "dev/model", source_agent_loop_public_id: "loop-1", source_task_key: "r1t1", ignored: "value" }
    response = request(daemon, :post, "/conversations/scheduled_jobs/create", token: bearer(daemon), body: body)
    assert_equal "201", response.code, response.body
    method, path, wire = api.job_writes.last
    assert_equal :post, method
    assert_equal "/agent_api/v1/workspaces/original/conversations/c-1/scheduled_jobs", path
    fields = wire.fetch("scheduled_job")
    assert_equal "daily", fields.dig("rule", "kind")
    assert_equal "loop-1", fields.fetch("source_agent_loop_public_id")
    refute fields.key?("ignored")
    response = request(daemon, :post, "/conversations/scheduled_jobs/update", token: bearer(daemon),
      body: { public_id: "c-1", job_public_id: "job-1", expected_lock_version: 3, name: nil })
    assert_equal "200", response.code, response.body
    assert_equal :patch, api.job_writes.last.first
    assert_equal({ "expected_lock_version" => 3, "name" => nil }, api.job_writes.last.last.fetch("scheduled_job"))
    %w[pause resume cancel].each do |operation|
      response = request(daemon, :post, "/conversations/scheduled_jobs/#{operation}", token: bearer(daemon),
        body: { public_id: "c-1", job_public_id: "job-1" })
      assert_equal "200", response.code, response.body
      assert api.job_writes.last[1].end_with?("/job-1/#{operation}")
    end
  end
end
