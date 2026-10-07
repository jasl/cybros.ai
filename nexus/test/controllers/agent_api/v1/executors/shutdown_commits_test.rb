require "test_helper"

class AgentAPI::V1::Executors::ShutdownCommitsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:owner)
    @manager = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    assert_equal :role_changed, @manager.change_role(to: :admin)
  end

  test "a manager shutdown keeps the claimed result and capture writable until transport is fenced" do
    agent_run, executor, secret, token = claimed_work
    assert_equal :removed, @manager.remove

    post agent_api_v1_executor_inbox_claim_path(run_public_id: agent_run.public_id, task_key: "loose"),
      headers: bearer(secret), as: :json
    assert_refused "not_eligible"

    AgentRuns::Parks::TimeoutSweep.call
    TaskExecutor.converge
    assert_equal "failed", node(agent_run, "loose").status
    assert_equal "dispatched", node(agent_run, "held").status
    assert_equal 1, executor.reload.credential_epoch

    post agent_api_v1_executor_inbox_extend_path(run_public_id: agent_run.public_id, task_key: "held"),
      headers: bearer(secret), as: :json, params: { claim_token: token, timeout_ms: 60_000 }
    assert_response :success

    post agent_api_v1_executor_progress_path, headers: bearer(secret), as: :json,
      params: { frame: { run_public_id: agent_run.public_id, task_key: "held", claim_token: token,
                         text_tail: "captured the result" } }
    assert_response :accepted

    capture = upload_capture(secret)
    commit(agent_run, secret, token, content: [
      { type: "text", text: "write completed" },
      { type: "resource_link", uri: "nexus://uploads/#{capture.public_id}", name: "result.txt" },
    ])
    assert_response :success
    held = node(agent_run, "held")
    assert_equal "completed", held.status
    assert_equal "write completed", held.output_preview
    assert_equal [capture.id], held.output_body.content_uploads.pluck(:id)

    TaskExecutor.converge
    assert_equal 2, executor.reload.credential_epoch
    assert_equal @manager.managed_resource_shutdown_generation, executor.applied_human_shutdown_generation
    commit(agent_run, secret, token, content: "late replay")
    assert_response :unauthorized
    assert_equal "write completed", node(agent_run, "held").output_preview
  end

  test "a paused claim can finish the accepted shutdown episode after its manager is restored" do
    agent_run, executor, secret, token = claimed_work
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    assert_equal :removed, @manager.remove
    assert_equal :restored, @manager.restore
    AgentRuns::Parks::TimeoutSweep.call
    TaskExecutor.converge
    assert_predicate executor.reload, :shutdown_pending?

    commit(agent_run, secret, token, content: "finished while paused")
    assert_response :success
    assert_equal "completed", node(agent_run, "held").status
    assert_equal "paused", agent_run.reload.status

    TaskExecutor.converge
    assert_not_predicate executor.reload, :shutdown_pending?
    assert_equal 2, executor.credential_epoch
  end

  test "a shutting down pool claimant still needs its own claim token" do
    agent_run, executor, secret, token = claimed_work(kind: :tool_provider)
    assert_nil node(agent_run, "held").addressed_executor_id
    assert_equal :removed, @manager.remove
    TaskExecutor.converge

    commit(agent_run, secret, "wrong", content: "unproven")
    assert_refused "stale_claim"
    assert_equal "dispatched", node(agent_run, "held").status
    assert_nil node(agent_run, "held").output_body

    commit(agent_run, secret, token, content: "provider finished")
    assert_response :success
    assert_equal "completed", node(agent_run, "held").status
    assert_equal executor.id, node(agent_run, "held").claimed_by_executor_id

    TaskExecutor.converge
    assert_equal 2, executor.reload.credential_epoch
    assert_equal "dispatched", node(agent_run, "loose").status,
      "the unclaimed pool row belongs to no departing executor"
  end

  private

    def claimed_work(kind: :runner)
      connection = connect_runner(manager: @manager, registration_identifier: "shutdown-#{kind}",
        assignment_scope: :account_wide, executor_kind: kind)
      executor = connection.executor_access_token.task_executor
      assert_predicate executor.announce(tools: [{ "name" => "write", "effect_profile" => WRITE_PROFILE }]), :accepted?
      route = { "kind" => "runner" } if kind == :runner
      steps = %w[held loose after].map do |key|
        { "tool" => { "key" => key, "name" => "write", "route" => route,
          "on_failure" => ("absorb" unless key == "after") }.compact }
      end
      agent_run = seed(parallel(*steps.first(2)), steps.last,
        default_runner_executor_public_id: (executor.public_id if kind == :runner))
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

      secret = connection.executor_access_secret
      post agent_api_v1_executor_inbox_claim_path(run_public_id: agent_run.public_id, task_key: "held"),
        headers: bearer(secret), as: :json
      assert_response :success
      [agent_run, executor, secret, response.parsed_body.fetch("claim").fetch("claim_token")]
    end

    def upload_capture(secret)
      Tempfile.create(["shutdown-result", ".txt"]) do |file|
        file.write("the captured result")
        file.flush
        upload = Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "result.txt")
        post agent_api_v1_executor_uploads_path, headers: bearer(secret), params: { upload: { file: upload } }
        assert_response :created
        ContentUpload.find_by!(public_id: response.parsed_body.fetch("upload").fetch("public_id"))
      end
    end

    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

    def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

    def commit(agent_run, secret, token, content:)
      post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id, task_key: "held"),
        headers: bearer(secret), as: :json, params: { claim_token: token, content: content, outcome: "completed" }
    end

    def assert_refused(code)
      assert_response :conflict
      assert_equal code, response.parsed_body.dig("error", "code")
    end
end
