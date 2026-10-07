require "test_helper"
require_relative "../support/ops_harness"

class OpsSchedulesTest < Minitest::Test
  include RhoTest::OpsHarness

  class JobsApi < NexusDoubles::FakeAgentApi
    attr_reader :job_writes

    def initialize(**options)
      super(workspaces: [{ public_id: "original", name: "Original workspace" }], **options)
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
      return super unless credential == NexusDoubles::MEMBER_TOKEN && path.include?("/schedules")

      if method == :get
        if path.end_with?("/executions")
          respond(200, { "executions" => [execution], "pagination" => { "next_after" => nil, "last_cursor" => "tail-1" } })
        elsif path.end_with?("/schedules")
          respond(200, { "schedules" => [@job], "pagination" => { "next_after" => "next-1" } })
        else
          respond(200, { "schedule" => @job })
        end
      else
        @job_writes << [method, path, body]
        respond(path.end_with?("/schedules") ? 201 : 200, { "schedule" => @job })
      end
    end
  end

  def test_human_schedule_captures_code_mode_and_explicit_tool_updates_cannot_expand_it
    api = JobsApi.new(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(extensions: nil, config: Rho::Config.from_hash({ "plugins" => { "rho.codemode" => { "configuration_version" => 1, "configuration" => { "default" => "off" } } } })), api, identity: RUNNER_IDENTITY)
    api.set_default_runner("c-1", RUNNER_IDENTITY.runner_executor_public_id)
    body = { public_id: "c-1", idempotency_key: "intent-off", prompt: "Report progress", model: "dev/model",
      rule: { kind: "once", run_at: "2026-10-06T09:00:00Z" } }
    response = request(daemon, :post, "/conversations/schedules/create", token: bearer(daemon), body: body)
    assert_equal "201", response.code, response.body
    names = api.job_writes.last.last.dig("schedule", "tool_names")
    refute_nil names
    refute_includes names, "code"
    assert_includes names, "read"
    response = request(daemon, :post, "/conversations/schedules/create", token: bearer(daemon),
      body: body.merge(idempotency_key: "intent-manual", tool_names: %w[read code]))
    assert_equal "201", response.code, response.body
    assert_equal ["read"], api.job_writes.last.last.dig("schedule", "tool_names")
    response = request(daemon, :post, "/conversations/schedules/update", token: bearer(daemon),
      body: { public_id: "c-1", job_public_id: "job-1", expected_lock_version: 3, tool_names: %w[read code] })
    assert_equal "200", response.code, response.body
    assert_equal ["read"], api.job_writes.last.last.dig("schedule", "tool_names")
    response = request(daemon, :patch, "/conversations/code_mode", token: bearer(daemon), body: { public_id: "c-1", code_mode: true })
    assert_equal "200", response.code, response.body
    response = request(daemon, :post, "/conversations/schedules/create", token: bearer(daemon), body: body.merge(idempotency_key: "intent-on"))
    assert_equal "201", response.code, response.body
    assert_includes api.job_writes.last.last.dig("schedule", "tool_names"), "code"
    response = request(daemon, :post, "/conversations/schedules/update", token: bearer(daemon),
      body: { public_id: "c-1", job_public_id: "job-1", expected_lock_version: 3, prompt: "Revise prompt" })
    assert_equal "200", response.code, response.body
    refute api.job_writes.last.last.fetch("schedule").key?("tool_names"), "an ordinary edit preserves an accepted schedule's tools"
  end

  def test_jobs_routes_share_authenticated_member_plane_without_a_local_host
    daemon = boot
    [[:get, "/conversations/schedules?public_id=c-1"],
     [:post, "/conversations/schedules/create"]].each do |method, path|
      assert_equal "401", request(daemon, method, path).code
      response = request(daemon, method, path, token: bearer(daemon), body: { public_id: "c-1" })
      assert_equal "409", response.code
      assert_equal "member_plane_unavailable", JSON.parse(response.body).dig("error", "code")
    end
  end

  def test_list_and_execution_reads_preserve_workspace_cursors_and_actual_child_status
    api = JobsApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :get, "/conversations/schedules?public_id=c-1&workspace_public_id=original&after=older&limit=7", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body)
    assert_equal "completed", document.dig("schedules", 0, "status")
    assert_equal "running", document.dig("schedules", 0, "last_execution", "status")
    assert_equal "next-1", document.dig("pagination", "next_after")
    path, credential, params = api.requests.last
    assert_equal "/agent_api/v1/workspaces/original/conversations/c-1/schedules", path
    assert_equal NexusDoubles::MEMBER_TOKEN, credential
    assert_equal({ "after" => "older", "limit" => 7 }, params)
    response = request(daemon, :get, "/conversations/schedules/executions?public_id=c-1&job_public_id=job-1&after=tail", token: bearer(daemon))
    document = JSON.parse(response.body)
    assert_equal "child-1", document.dig("executions", 0, "child_conversation_public_id")
    assert_equal "tail-1", document.dig("pagination", "last_cursor")
    assert_empty daemon.lineage.followers
  end

  def test_create_update_and_state_commands_forward_only_the_authoring_contract
    api = JobsApi.new
    daemon = member_ready(boot, api)
    body = { public_id: "c-1", workspace_public_id: "original", idempotency_key: "intent-1",
      prompt: "Report progress", rule: { kind: "daily", local_time: "09:00", time_zone: "Asia/Shanghai" },
      model: "dev/model", reasoning_enabled: false, reasoning_effort: "high",
      source_run_public_id: "run-1", source_task_key: "r1t1", ignored: "value" }
    response = request(daemon, :post, "/conversations/schedules/create", token: bearer(daemon), body: body)
    assert_equal "201", response.code, response.body
    method, path, wire = api.job_writes.last
    assert_equal :post, method
    assert_equal "/agent_api/v1/workspaces/original/conversations/c-1/schedules", path
    fields = wire.fetch("schedule")
    assert_equal "daily", fields.dig("rule", "kind")
    assert_equal({ "model" => "dev/model", "reasoning_enabled" => false, "reasoning_effort" => "high" }, fields.fetch("model"))
    assert_equal "run-1", fields.fetch("source_run_public_id")
    refute fields.key?("ignored")
    response = request(daemon, :post, "/conversations/schedules/update", token: bearer(daemon),
      body: { public_id: "c-1", job_public_id: "job-1", expected_lock_version: 3, name: nil, reasoning_enabled: false })
    assert_equal "200", response.code, response.body
    assert_equal :patch, api.job_writes.last.first
    assert_equal({ "expected_lock_version" => 3, "name" => nil, "model" => { "reasoning_enabled" => false } },
      api.job_writes.last.last.fetch("schedule"))
    %w[pause resume cancel].each do |operation|
      response = request(daemon, :post, "/conversations/schedules/#{operation}", token: bearer(daemon),
        body: { public_id: "c-1", job_public_id: "job-1" })
      assert_equal "200", response.code, response.body
      assert api.job_writes.last[1].end_with?("/job-1/#{operation}")
    end
  end
end
