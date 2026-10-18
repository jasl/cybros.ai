require "test_helper"
require_relative "../../../test_helpers/runs_execution_test_helper"

class Runs::Mcp::ExecuteTest < ActiveJob::TestCase
  include RunsExecutionTestHelper

  Client = Data.define(:handler) do
    def call_tool(name:, arguments:) = handler.call(name, arguments)
  end

  setup do
    @agent = users(:agent)
    @connection = @agent.steward.mcp_connections.create!(
      name: "Work account", account_label: "Work", endpoint_url: "https://mcp.example.test/tools",
      auth_type: "bearer", bearer_token: "test-mcp-token",
      catalog: [{ "name" => "write", "description" => "Write a record", "input_schema" => { "type" => "object" } }]
    )
    @opens = []
    @calls = []
  end

  test "Nexus executes one generation once without a Runner or executor claim" do
    run, task = ready_call
    with_client do
      execute(task)
      execute(task)
    end

    assert_equal [["write", { "value" => "hello" }]], @calls
    assert_equal "completed", task.reload.status
    assert_not_nil task.external_started_at
    assert_nil task.claimed_at
    assert_nil task.addressed_executor_id
    assert_nil run.default_runner_executor_id
    assert_equal "saved", task.output_body.effective_text
    assert_equal "test-mcp-token", @opens.sole.fetch(:bearer_token)
    assert_equal({ kind: "mcp", connection_public_id: @connection.public_id,
      display_name: "Work account", account_label: "Work", tool_name: "write" },
      Runs::TaskProjection.target(task))
  end

  test "model tools require approval and keep their callable and connection" do
    run, task = model_call(approval_mode: "ask")
    assert_equal "needs_approval", task.status
    assert_equal "model", task.authored_by
    assert_equal "work_write", task.called_name
    assert_equal @connection.public_id, task.mcp_connection_public_id
    with_client { execute(task) }
    assert_empty @opens

    approved = Runs::Tasks::Approve.call(Runs::Tasks::Approve::Command.new(
      run: run, task_key: task.node_key, acting_user: @human
    ))
    assert_predicate approved, :accepted?
    with_client { execute(task.reload) }
    assert_equal "completed", task.reload.status
    assert_equal "human", task.approval_origin
  end

  test "rules match the selected callable rather than another account's remote name" do
    _, allowed = model_call(approval_mode: "rules", approval_rules: [{ "tool" => "work_write", "verdict" => "allow" }])
    assert_equal "running", allowed.status
    _, denied = model_call(approval_mode: "rules", approval_rules: [{ "tool" => "personal_write", "verdict" => "allow" }])
    assert_equal "failed", denied.status
    assert_equal "approval_denied", denied.error_key
  end

  test "steward transfer after dispatch and before IO rejects the captured connection without sending" do
    _, task = ready_call
    users(:member).mcp_connections.create!(name: @connection.name, endpoint_url: "https://replacement.example.test/mcp",
      auth_type: "none", catalog: @connection.tools_catalog)
    assert_equal :changed, @agent.change_steward(to: users(:member))
    with_client { execute(task) }

    assert_empty @opens
    assert_nil task.reload.external_started_at
    assert_equal @connection.public_id, task.mcp_connection_public_id
    assert_equal "failed", task.status
    assert_includes task.output_body.effective_text, "mcp_connection_unavailable"
  end

  test "connection disable after dispatch and before IO fails without sending" do
    _, task = ready_call
    @connection.update!(enabled: false)
    with_client { execute(task) }

    assert_empty @opens
    assert_nil task.reload.external_started_at
    assert_equal "failed", task.status
    assert_includes task.output_body.effective_text, "mcp_connection_unavailable"
  end

  test "credential rotation is read at start and contains no secret in task history" do
    run, task = ready_call
    @connection.update!(bearer_token: "rotated-mcp-token")
    with_client { execute(task) }

    assert_equal "rotated-mcp-token", @opens.sole.fetch(:bearer_token)
    projection = AgentAPI::RunPresenter.task(task.reload).to_json
    events = run.event_items.map(&:payload).to_json
    refute_includes projection + events + task.attributes.to_json, "rotated-mcp-token"
  end

  test "a possibly sent failure becomes uncertain and is never automatically replayed" do
    _, task = ready_call
    with_client(handler: ->(*) { raise Mcp::Error.new(:mcp_transport_error, request_sent: true) }) do
      execute(task)
      execute(task)
    end
    assert_equal "uncertain", task.reload.status
    assert_equal "tool_uncertain", task.error_key
    assert_equal 1, @opens.length
  end

  test "a known unsent failure is definite even after the start record was committed" do
    _, task = ready_call
    with_client(handler: ->(*) { raise Mcp::Error.new(:mcp_cancelled, request_sent: false) }) { execute(task) }
    assert_equal "failed", task.reload.status
    assert_not_nil task.external_started_at
  end

  test "a crashed sender expires uncertain while an unstarted call expires timed out" do
    _, started = ready_call(timeout_ms: 1000)
    with_client(handler: ->(*) { raise "worker died" }) { assert_raises(RuntimeError) { execute(started) } }
    _, unstarted = ready_call(timeout_ms: 1000)
    now = [started.reload.deadline_at, unstarted.deadline_at].max + 1.second
    travel_to(now) do
      DatabaseClock.stub(:now, now) do
        Runs::Parks::Settle.call(node: started, timeout: true)
        Runs::Parks::Settle.call(node: unstarted, timeout: true)
      end
    end
    assert_equal "uncertain", started.reload.status
    assert_equal "timed_out", unstarted.reload.status
  end

  test "retry clears the start and old jobs and responses cannot reach the new generation" do
    run, task = ready_call
    with_client(handler: ->(*) { raise Mcp::Error.new(:mcp_transport_error, request_sent: true) }) { execute(task) }
    old_generation = task.reload.execution_generation
    retried = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run.reload, task_key: task.node_key, acting_user: @human
    ))
    assert_predicate retried, :accepted?
    schedule!(run)
    assert_nil task.reload.external_started_at
    with_client do
      Runs::Mcp::Execute.call(node_id: task.id, execution_generation: old_generation)
      stale = Runs::Parks::Settle.call(node: task, trusted: true,
        execution_generation: old_generation, content: "old response")
      refute_predicate stale, :moved?
      execute(task)
    end
    assert_equal "completed", task.reload.status
    assert_equal "saved", task.output_body.effective_text
    assert_equal 2, @opens.length
  end

  test "Pause and maintenance defer starts and the existing scheduler recovers their wake" do
    run, task = ready_call
    paused = Runs::Pause.call(Runs::Pause::Command.graceful(run: run, acting_user: @human))
    assert_predicate paused, :accepted?
    with_client { execute(task) }
    assert_empty @opens
    Runs::Resume.call(Runs::Resume::Command.new(run: run.reload, acting_user: @human))
    @account.update!(maintenance_started_at: Time.current)
    with_client { execute(task) }
    assert_empty @opens
    assert_equal 0, Deployments::Maintenance.status.fetch(:kernel_tools)
    @account.update!(maintenance_started_at: nil)
    assert_enqueued_with(job: Runs::McpToolJob, args: [task.id, task.execution_generation]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    with_client { execute(task) }
    assert_equal "completed", task.reload.status
  end

  test "Stop before IO cancels immediately and a stopped sender cannot publish a late result" do
    run, task = ready_call
    Runs::Stop.call(Runs::Stop::Command.new(run: run, acting_user: @human, force: false))
    with_client { execute(task) }
    assert_empty @opens
    assert_equal "canceled", task.reload.status

    run, task = ready_call
    with_client(handler: ->(*) {
      Runs::Stop.call(Runs::Stop::Command.new(run: run.reload, acting_user: @human, force: true))
      { "content" => [{ "type" => "text", "text" => "late" }] }
    }) { execute(task) }
    assert_equal "canceled", task.reload.status
    assert_nil task.output_body
  end

  test "connection disable after start does not invalidate its original result" do
    _, task = ready_call
    with_client(handler: ->(*) {
      @connection.update!(enabled: false)
      { "content" => [{ "type" => "text", "text" => "already done" }], "isError" => true }
    }) { execute(task) }
    assert_equal "completed", task.reload.status
    assert_equal true, task.output_summary.fetch("is_error")
  end

  test "steward transfer after start keeps the result on its original task and connection" do
    run, task = ready_call
    with_client(handler: ->(*) {
      assert_equal :changed, @agent.change_steward(to: users(:member))
      { "content" => [{ "type" => "text", "text" => "already written" }] }
    }) { execute(task) }

    assert_equal "completed", task.reload.status
    assert_equal "already written", task.output_body.effective_text
    assert_equal run.id, task.run_id
    assert_equal @connection.public_id, task.mcp_connection_public_id
    assert_equal 1, @opens.length
  end

  private

    def ready_call(timeout_ms: 60_000)
      run = seed({ "tool" => { "key" => "send", "name" => "write", "input" => { "value" => "hello" },
        "timeout_ms" => timeout_ms, "on_failure" => "halt", "route" => {
          "kind" => "mcp", "connection_public_id" => @connection.public_id,
        } } }, creating_user: @agent, default_runner_executor_public_id: nil)
      start!(run)
      [run, node(run, "send")]
    end

    def model_call(**approval)
      declaration = { "type" => "function", "function" => { "name" => "work_write", "parameters" => { "type" => "object" } },
        "route" => { "kind" => "mcp", "connection_public_id" => @connection.public_id, "tool_name" => "write" } }
      run = seed(model("plan", "tools" => [declaration]), creating_user: @agent,
        default_runner_executor_public_id: nil, **approval)
      start!(run)
      run_step!(run, sse_success("writing", tool_calls: [{ id: "mcp-call", name: "work_write", arguments: "{}" }]), key: "plan")
      [run, run.tasks.find_by!(tool_call_id: "mcp-call")]
    end

    def execute(task)
      Runs::Mcp::Execute.call(node_id: task.id, execution_generation: task.execution_generation)
    end

    def with_client(handler: nil)
      handler ||= ->(name, input) {
        @calls << [name, input]
        { "content" => [{ "type" => "text", "text" => "saved" }] }
      }
      open = ->(**options, &block) { @opens << options; block.call(Client.new(handler: handler)) }
      Mcp::Client.stub(:open, open) { yield }
    end
end
