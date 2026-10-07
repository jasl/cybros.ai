require "test_helper"
require "test_helpers/agent_run_api_test_helper"

class AgentAPI::V1::AgentRunLifecycleTest < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper

  test "the lifecycle verbs move the loop and wrong states answer as conflicts" do
    loop_id = create_loop!

    post "#{loops_path}/#{loop_id}/pause", headers: auth
    assert_response :conflict
    assert_equal "not_pausable", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success
    assert_equal "running", response.parsed_body.dig("run", "status")
    assert_not_nil response.parsed_body.dig("run", "started_at")

    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :conflict

    post "#{loops_path}/#{loop_id}/pause", headers: auth
    assert_response :success
    assert_equal "paused", response.parsed_body.dig("run", "status")

    post "#{loops_path}/#{loop_id}/resume", headers: auth
    assert_response :success
    assert_equal "running", response.parsed_body.dig("run", "status")

    post "#{loops_path}/#{loop_id}/pause", headers: auth, as: :json,
      params: { force: true }
    assert_response :success
    assert_equal "paused", response.parsed_body.dig("run", "status"),
      "pause escalates with force even when already paused"

    post "#{loops_path}/#{loop_id}/resume", headers: auth
    assert_response :success

    post "#{loops_path}/#{loop_id}/stop", headers: auth, as: :json,
      params: { force: false }
    assert_response :success
    assert_includes %w[canceling canceled],
      response.parsed_body.dig("run", "status")

    post "#{loops_path}/#{loop_id}/stop", headers: auth
    assert_response :success, "stopping again (forced default) escalates idempotently"
  end

  test "a malformed force is refused, never coerced into the destructive default" do
    loop_id = create_loop!
    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success

    post "#{loops_path}/#{loop_id}/stop", headers: auth, as: :json, params: { force: "false" }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    assert_equal "running", AgentRun.find_by!(public_id: loop_id).status,
      "a string force must not fall through to stop's forced default"
  end

  test "a task reads back with its full output, and adjudication verbs answer in task vocabulary" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    node = agent_run.agent_run_tasks.sole
    node.update!(status: "failed", completed_at: Time.current,
      error_key: "provider_http_error", error_detail: "HTTP 400: bad request (invalid_request_error)")
    agent_run.update!(status: "needs_attention", attention_reason: "halt_failure",
      started_at: Time.current)

    get "#{loops_path}/#{loop_id}/tasks/seed", headers: auth
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "failed", task["status"]
    assert_equal "provider_http_error", task.dig("error", "key")
    assert_equal "HTTP 400: bad request (invalid_request_error)", task.dig("error", "detail"),
      "the task reads back what the provider answered (12a F-5)"

    post "#{loops_path}/#{loop_id}/tasks/seed/retry", headers: auth
    assert_response :success
    assert_equal "waiting", response.parsed_body.dig("task", "status")
    assert_nil response.parsed_body.dig("task", "error")
    assert_equal "running", agent_run.reload.status

    post "#{loops_path}/#{loop_id}/tasks/seed/abandon", headers: auth
    assert_response :conflict
    assert_equal "not_abandonable", response.parsed_body.dig("error", "code")
  end

  test "a model retry resolves the supplied selection and refuses an unavailable replacement without changing the task" do
    DevModelLane.ensure_enabled!(@account)
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    node = agent_run.agent_run_tasks.sole
    node.update!(status: "failed", completed_at: Time.current, error_key: "provider_model_unavailable")
    agent_run.update!(status: "needs_attention", attention_reason: "halt_failure", started_at: Time.current)

    post "#{loops_path}/#{loop_id}/tasks/seed/retry", headers: auth, as: :json,
      params: { model: { model: "dev/missing" } }
    assert_response :conflict
    assert_equal "unknown_model", response.parsed_body.dig("error", "code")
    assert_equal "failed", node.reload.status
    assert_equal 0, node.execution_generation

    post "#{loops_path}/#{loop_id}/tasks/seed/retry", headers: auth, as: :json,
      params: { model: { model: "dev/mock-unmetered" } }
    assert_response :success
    assert_equal "mock-unmetered", node.reload.model_ref
    assert_equal 1, node.execution_generation
    assert_equal "running", agent_run.reload.status
  end

  # THE PERSON-SIDE BRANCH CANCEL: a detached step is a branch; the seed is the mainline, and the
  # mainline's verb is `stop`.
  test "the cancel verb settles a branch canceled and refuses the mainline in task vocabulary" do
    loop_id = create_loop!
    post "#{loops_path}/#{loop_id}/tasks", headers: auth(SecureRandom.uuid), as: :json, params: {
      steps: [{ tool: { key: "bg", name: "shell", detached: true } }],
    }
    assert_response :created
    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success

    post "#{loops_path}/#{loop_id}/tasks/seed/cancel", headers: auth
    assert_response :conflict
    assert_equal "not_a_branch", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/tasks/bg/cancel", headers: auth
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal %w[canceled canceled task_canceled],
      [task["status"], task["failure_resolution"], task.dig("error", "key")]
    assert_not task.key?("result_delivered_at"), "nothing mailed a standalone loop's tip"

    post "#{loops_path}/#{loop_id}/tasks/bg/cancel", headers: auth
    assert_response :conflict
    assert_equal "already_terminal", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/tasks/nope/cancel", headers: auth
    assert_response :not_found
  end

  # COMPACT NOW, task-grained. The kernel still picks no threshold; this
  # is a caller asking, which the wall-only trigger never left room for.
  test "the compact verb names the summarizer it authored, and refuses in task vocabulary" do
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", steps: [
        { model: { key: "one", model: MODEL, prompt: "start" } },
        { model: { key: "two", model: MODEL, prompt: "keep going" } },
      ] },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")

    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success

    post "#{loops_path}/#{loop_id}/tasks/nope/compact", headers: auth
    assert_response :not_found

    post "#{loops_path}/#{loop_id}/tasks/two/compact", headers: auth
    assert_response :accepted
    summary_key = response.parsed_body.fetch("summary_task_key")
    assert_equal "waiting", response.parsed_body.dig("task", "status")

    get "#{loops_path}/#{loop_id}/tasks/#{summary_key}", headers: auth
    assert_response :success
    assert_equal "model_task", response.parsed_body.dig("task", "kind")

    post "#{loops_path}/#{loop_id}/tasks/two/compact", headers: auth
    assert_response :conflict
    assert_equal "already_compacted", response.parsed_body.dig("error", "code"),
      "compacting a compaction is a loop, not a repair"
  end

  test "the resolution door takes the token as a second factor" do
    post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
      run: { approval_mode: "bypass", steps: [{ ask: { key: "gate", prompt: "?" } }] },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")
    token = response.parsed_body.dig("receipt", "resolution_tokens", "gate")
    assert_not_nil token, "the token travels in the creator's receipt and nowhere else"

    get "#{loops_path}/#{loop_id}", headers: auth
    assert_not_includes response.body, token, "the trace never carries it"

    agent_run = loop_record(loop_id)
    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: SecureRandom.uuid, content: "forged" }
    assert_response :conflict
    assert_equal "stale_claim", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: token, outcome: "sideways" }
    assert_response :unprocessable_entity
    assert_equal "invalid_outcome", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: token, content: "the answer" }
    assert_response :success
    assert_equal "completed", response.parsed_body.dig("task", "status")

    post "#{loops_path}/#{loop_id}/tasks/nope/resolution", headers: auth, as: :json,
      params: { resolution_token: token }
    assert_response :not_found
  end

  # WHO ANSWERED: any principal with standing answers an await; the fact is the acting user's KIND
  # and id on the settle's own narration item — the approval-origin precedent, no column, no proxy
  # machinery. A child's relay says `conversation`.
  test "the resolution door records who resolved the await: the acting user's kind and id" do
    loop_id = create_await_loop!
    token = response.parsed_body.dig("receipt", "resolution_tokens", "gate")
    post "#{loops_path}/#{loop_id}/start", headers: auth
    AgentRuns::ScheduleReady.call(agent_run_id: loop_record(loop_id).id)
    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", headers: auth, as: :json,
      params: { resolution_token: token, content: "the answer" }
    assert_response :success
    resolved = task_status_payloads(loop_id, "gate").last
    assert_equal({ "kind" => "human", "public_id" => @human.public_id, "handle" => @human.handle },
      resolved.fetch("resolved_by"), "kind, id and the handle a person reads")
    assert_equal "completed", resolved.fetch("status")

    agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: agent.agent_identifier)
    loop_id = create_await_loop!
    token = response.parsed_body.dig("receipt", "resolution_tokens", "gate")
    post "#{loops_path}/#{loop_id}/start", headers: auth
    AgentRuns::ScheduleReady.call(agent_run_id: loop_record(loop_id).id)
    post "#{loops_path}/#{loop_id}/tasks/gate/resolution", as: :json,
      headers: { "Authorization" => "Bearer #{connection.access_secret}" },
      params: { resolution_token: token, content: "an agent's answer" }
    assert_response :success
    assert_equal({ "kind" => "agent", "public_id" => agent.public_id, "handle" => agent.handle },
      task_status_payloads(loop_id, "gate").last.fetch("resolved_by"), "an agent's answer is recorded as an agent's")
  end

  # THE APPROVER'S VERBS over HTTP, the adjudicate shape: a rule naming `origin: author` parks an
  # authored `read_file` under `ask`, and the person decides it — approve releases it to the runner,
  # deny fails it `approval_denied` with the reason as the detail the model reads.
  test "approve and deny answer in task vocabulary, and refuse a row that is not resting" do
    shell = { approval_mode: "ask", approval_rules: [{ tool: "read_file", verdict: "ask", origin: "author" }] }
    runner = suite_runner
    held = ->(key) {
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        run: shell.merge(steps: [{ tool: { key: key, name: "read_file", route: { kind: "runner" } } }],
          default_runner_executor_public_id: runner.public_id),
      }
      assert_response :created
      loop_id = response.parsed_body.dig("run", "public_id")
      post "#{loops_path}/#{loop_id}/start", headers: auth
      assert_response :success
      perform_enqueued_jobs(only: AgentRuns::ScheduleJob)
      get "#{loops_path}/#{loop_id}/tasks/#{key}", headers: auth
      assert_equal "needs_approval", response.parsed_body.dig("task", "status")
      assert_nil response.parsed_body.dig("task", "approval")
      loop_id
    }

    loop_id = held.("probe")
    post "#{loops_path}/#{loop_id}/tasks/probe/approve", headers: auth
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "dispatched", task["status"]
    assert_equal "runner", task.dig("addressed_to", "role")
    assert_equal "human", task.dig("approval", "origin")
    assert_equal @human.public_id, task.dig("approval", "decided_by")
    assert_not_nil task.dig("approval", "decided_at")

    post "#{loops_path}/#{loop_id}/tasks/probe/approve", headers: auth
    assert_response :conflict
    assert_equal "not_awaiting_approval", response.parsed_body.dig("error", "code"), "a settled row is not resting"
    post "#{loops_path}/#{loop_id}/tasks/nope/deny", headers: auth
    assert_response :not_found

    loop_id = held.("probe")
    post "#{loops_path}/#{loop_id}/tasks/probe/deny", headers: auth, as: :json, params: { reason: "use ls" }
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "failed", task["status"]
    assert_equal({ "key" => "approval_denied", "detail" => "use ls" }, task.fetch("error"))
    assert_equal "human", task.dig("approval", "origin")
    assert_equal @human.public_id, task.dig("approval", "decided_by")

    post "#{loops_path}/#{loop_id}/tasks/probe/deny", headers: auth, as: :json, params: { reason: ["x"] }
    assert_response :bad_request, "a reason is text or nothing"

    # The verbs are WRITES: the gate every adjudication verb holds.
    loop_id = held.("probe")
    @workspace.update_column(:state, "archived")
    post "#{loops_path}/#{loop_id}/tasks/probe/approve", headers: auth
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  ensure
    @workspace.update_column(:state, "active")
  end

  test "late approve and deny return conflict while committing the park expiry" do
    %w[approve deny].each do |verb|
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        run: {
          approval_mode: "ask", approval_rules: [{ tool: "read_file", verdict: "ask", origin: "author" }],
          steps: [{ tool: { key: "probe", name: "read_file", route: { kind: "runner" }, on_failure: "halt" } }],
          default_runner_executor_public_id: suite_runner.public_id,
        },
      }
      assert_response :created
      loop_id = response.parsed_body.dig("run", "public_id")
      post "#{loops_path}/#{loop_id}/start", headers: auth
      assert_response :success
      perform_enqueued_jobs(only: AgentRuns::ScheduleJob)
      task = loop_record(loop_id).agent_run_tasks.sole
      assert_equal "needs_approval", task.status
      task.update!(await_started_at: 25.hours.ago)

      post "#{loops_path}/#{loop_id}/tasks/probe/#{verb}", headers: auth
      assert_response :conflict
      assert_equal "not_awaiting_approval", response.parsed_body.dig("error", "code")

      get "#{loops_path}/#{loop_id}/tasks/probe", headers: auth
      assert_response :success
      assert_equal "timed_out", response.parsed_body.dig("task", "status")
      assert_equal "approval_expired", response.parsed_body.dig("task", "error", "key")
      assert_nil response.parsed_body.dig("task", "approval")
    end
  end

  test "delete tombstones a settled loop and refuses a live one" do
    loop_id = create_loop!
    agent_run = loop_record(loop_id)
    agent_run.update!(status: "running")

    delete "#{loops_path}/#{loop_id}", headers: auth
    assert_response :conflict
    assert_equal "run_busy", response.parsed_body.dig("error", "code")

    agent_run.update!(status: "completed")
    delete "#{loops_path}/#{loop_id}", headers: auth
    assert_response :no_content
    assert_not_nil agent_run.reload.tombstoned_at

    get "#{loops_path}/#{loop_id}", headers: auth
    assert_response :not_found, "a tombstone leaves every product surface at once"
  end
end
