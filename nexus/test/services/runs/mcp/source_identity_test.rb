require "test_helper"
require_relative "../../../test_helpers/runs_execution_test_helper"

class Runs::Mcp::SourceIdentityTest < ActiveJob::TestCase
  include RunsExecutionTestHelper

  Client = Data.define(:text) do
    def call_tool(name:, arguments:) = { "content" => [{ "type" => "text", "text" => text }] }
  end

  setup do
    @agent = users(:agent)
    @connection = mcp_connections(:notes)
    assert_equal :changed, @agent.change_steward(to: @connection.owner)
    names = %w[skill spawn tool_call]
    @connection.update!(catalog: names.map { |name|
      { "name" => name, "description" => "Remote #{name}", "input_schema" => { "type" => "object" } }
    })
  end

  test "a remote skill name remains an ordinary model tool without a skill document source" do
    run = seed(model("plan", "tools" => [declaration("skill")]), creating_user: @agent,
      default_runner_executor_public_id: nil)
    start!(run)

    plan = node(run, "plan")
    assert_empty plan.operation_context.dig("environment", "skills")
    assert_equal ["remote_skill"], Nexus::ToolDeclarations.names(plan.selected_model_invocation.request_options.fetch("tools"))
    run_step!(run, sse_success("calling", tool_calls: [remote_call("skill")]), key: "plan")
    execute(run.tasks.find_by!(tool_call_id: "remote-skill"), "Remote skill result")
    request = build(step_attempt(run, key: "r1"))
    assert_predicate request, :built?
    assert_includes request.request.payload, "Remote skill result"
  end

  test "waiting on a completed remote spawn reads its result rather than a nonexistent child conversation" do
    run = seed({ "tool" => { "key" => "remote", "name" => "spawn", "route" => route,
      "input" => {}, "on_failure" => "halt" } }, { "wait" => { "key" => "observed", "task" => "remote" } },
      creating_user: @agent, default_runner_executor_public_id: nil)
    start!(run)
    execute(node(run, "remote"), "Remote spawn result")

    observed = node(run, "observed")
    assert_equal "completed", observed.status
    assert_equal "Remote spawn result", AgentAPI::RunPresenter.task_detail(observed)
      .fetch(:structured_content).fetch("results").sole.fetch("output")
  end

  %w[spawn tool_call].each do |name|
    test "a remote #{name} call inside delegated work retains its branch cancellation boundary" do
      run = seed(model("plan", "tools" => [Nexus::Tools::DELEGATE_TASK, declaration(name)]),
        creating_user: @agent, default_runner_executor_public_id: nil)
      start!(run)
      run_step!(run, sse_success("delegate", tool_calls: [{ id: "delegate", name: "delegate_task",
        arguments: { prompt: "Use the remote tool", wait: true }.to_json }]), key: "plan")
      Runs::DelegateTaskToolJob.perform_now(node(run, "r1t0").id)
      schedule!(run)
      run_step!(run, sse_success("calling", tool_calls: [remote_call(name)]), key: "r1t0-model-1")
      remote = run.tasks.find_by!(tool_call_id: "remote-#{name}")

      assert_equal %w[r2 r2t0], Runs::BranchClosure.members(remote).map(&:node_key).sort
      result = Runs::CancelBranch.call(Runs::CancelBranch::Command.new(
        run: run, task_key: remote.node_key, acting_user: @human))
      assert_predicate result, :accepted?
      assert_equal %w[canceled canceled], [remote.reload.status, node(run, "r2").status]
      refute_equal "canceled", node(run, "r1").status
    end
  end

  private

    def route = { "kind" => "mcp", "connection_public_id" => @connection.public_id }

    def declaration(name)
      { "type" => "function", "function" => { "name" => "remote_#{name}",
        "description" => "Remote #{name}", "parameters" => { "type" => "object" } },
        "route" => route.merge("tool_name" => name) }
    end

    def remote_call(name) = { id: "remote-#{name}", name: "remote_#{name}", arguments: "{}" }

    def execute(task, text)
      open = ->(**, &block) { block.call(Client.new(text: text)) }
      ::Mcp::Client.stub(:open, open) do
        Runs::Mcp::Execute.call(node_id: task.id, execution_generation: task.execution_generation)
      end
      assert_equal "completed", task.reload.status
      schedule!(task.run)
    end
end
