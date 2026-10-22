require "test_helper"

class Executors::TaskOperations::ContextTest < ActiveJob::TestCase
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @application = executors(:address)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an unaddressed standalone tool waits for dispatch before selecting its application capture" do
    announce_tools!(@agent, ["application_work"])
    context = { "root" => "/accepted" }
    run = seed(tool("work", "application_work", "model_defaults" => {
      "executor_contexts" => { @application.public_id => context },
    }), creating_user: @agent)
    call = run.tasks.sole

    assert_nil Executors::TaskOperations::Context.executor_context(call)
    assert_nil Executors::TaskOperations::Context.executor_context(call, executor: @application)

    assert_predicate Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @agent)), :accepted?
    schedule_loop!(run)

    assert_equal @application, call.reload.addressed_executor
    assert_equal context, Executors::TaskOperations::Context.executor_context(call)
    assert_equal context, Executors::TaskOperations::Context.executor_context(call, executor: suite_runner)
  end

  test "an explicit empty context keeps precedence over a map with no matching target" do
    run = seed(tool("read", "read_file", "executor_context" => {}, "model_defaults" => {
      "executor_contexts" => { @application.public_id => { "root" => "/application" } },
    }))

    assert_equal({}, Executors::TaskOperations::Context.executor_context(run.tasks.sole, executor: @application))
  end
end
