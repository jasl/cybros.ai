require "test_helper"

class Executors::RunnerTargetsTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def runner_a = suite_runner

  def runner_b
    @runner_b ||= connect_runner(manager: @owner, registration_identifier: "targets-b",
      display_name: "Build", assignment_scope: :account_wide).executor_access_token.task_executor.tap do |runner|
      runner.announce(tools: [{ "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])
    end
  end

  def declaration(name, runner, served: "read")
    {
      "type" => "function",
      "function" => { "name" => name, "description" => "Read exactly this environment",
        "parameters" => { "type" => "object", "properties" => { "path" => { "type" => "string" } },
          "required" => ["path"], "additionalProperties" => false } },
      "route" => { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => served },
    }
  end

  def selected(host, target)
    Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: host, executor_public_id: target&.public_id, acting_user: @human))
  end

  def task(run, key) = run.agent_run_tasks.find_by!(node_key: key)

  def start(run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: run, acting_user: @human))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: run.id)
    clear_enqueued_jobs
  end

  test "two exact function schemas retain distinct immutable targets and provider wire strips routes" do
    definitions = Nexus::ToolDeclarations.canonical([declaration("mac_read", runner_a), declaration("build_read", runner_b)])
    run = seed(model("plan", "tools" => definitions))
    source = task(run, "plan")
    assert_equal definitions, source.tool_definitions
    assert_equal definitions.map { |entry| entry.except("route").deep_merge("function" => { "strict" => false }) },
      Nexus::ToolDeclarations.wire(source.tool_definitions)

    selected(run, runner_b)
    steps = Executors::TaskOperations::Lower.new(source).call([
      { "tool" => { "name" => "mac_read", "input" => { "path" => "a" } } },
      { "tool" => { "name" => "build_read", "input" => { "path" => "b" } } },
    ])
    receipt = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: run, steps: steps, tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH),
      origin: "model", expansion_parent: source))
    assert_predicate receipt, :applied?, receipt.outcome.to_s
    children = run.agent_run_tasks.where(node_key: receipt.receipt.fetch("accepted_task_keys")).order(:id)
    assert_equal [runner_a.public_id, runner_b.public_id], children.map(&:target_executor_public_id)
    assert_equal %w[read read], children.map(&:tool_name)
    assert_equal %w[mac_read build_read], children.map(&:tool_alias)
    assert_equal runner_a.public_id,
      Executors::TaskOperations::Context.defaults(children.first).dig("environment", "default_runner_executor_public_id")
  end

  test "a continuation cannot change a declared target and narrowing retains route identity" do
    definitions = [declaration("read_a", runner_a)]
    run = seed(model("plan", "tools" => definitions))
    lower = Executors::TaskOperations::Lower.new(task(run, "plan"))
    error = assert_raises(Executors::TaskOperations::Lower::Refusal) do
      lower.call([{ "tool" => { "name" => "read_a", "route" => {
        "kind" => "runner", "runner_executor_public_id" => runner_b.public_id,
      } } }])
    end
    assert_equal :tool_route_mismatch, error.code
    assert_empty Nexus::ToolDeclarations.intersection_names([declaration("read_a", runner_b)], inherited: definitions)
  end

  test "default absence is allowed and only an explicit Runner request needs a target" do
    run = seed({ "tool" => { "key" => "plain", "name" => "read" } }, default_runner_executor_public_id: nil)
    assert_nil task(run, "plain").target_executor_public_id
    start(run)
    assert_equal "tool_not_served", task(run, "plain").error_key

    refused = create_loop({ "tool" => { "name" => "read", "route" => { "kind" => "runner" } } },
      default_runner_executor_public_id: nil)
    assert_equal :runner_target_required, refused.outcome
  end

  test "an explicit null target and malformed declaration routes fail at the boundary" do
    step = { "tool" => { "name" => "read", "route" => { "kind" => "runner", "runner_executor_public_id" => nil } } }
    result = create_loop(step)
    assert_equal :invalid_steps, result.outcome
    assert_equal "invalid_tool_route", result.errors.sole.fetch("code")
    result = create_loop({ "tool" => { "name" => "read", "route" => nil } })
    assert_equal "invalid_tool_route", result.errors.sole.fetch("code")
    entry = declaration("read_a", runner_a)
    entry.fetch("route").delete("runner_executor_public_id")
    assert_equal "runner_target_required", Nexus::ToolDeclarations.refusal([entry])
  end

  test "withdrawal cannot fall through to a same named tool on the changed default" do
    run = seed({ "tool" => { "key" => "read-a", "name" => "read", "route" => { "kind" => "runner" } } })
    selected(run, runner_b)
    runner_a.announce(tools: [])
    start(run)
    row = task(run, "read-a")
    assert_equal runner_a.public_id, row.target_executor_public_id
    assert_equal "tool_not_served", row.error_key
    assert_nil row.addressed_executor_id
  end

  test "an accepted create replay does not resolve the changed target again" do
    step = { "tool" => { "key" => "read-a", "name" => "read", "route" => { "kind" => "runner" } } }
    first = create_loop(step, idempotency_key: "frozen-target")
    assert_predicate first, :created?
    selected(first.agent_run, runner_b)
    runner_a.revoke_credentials
    replay = create_loop(step, idempotency_key: "frozen-target")
    assert_predicate replay, :replayed?, replay.outcome.to_s
    assert_equal runner_a.public_id, task(replay.agent_run, "read-a").target_executor_public_id
  end
end
