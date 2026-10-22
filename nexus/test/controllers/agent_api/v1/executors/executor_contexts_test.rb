require "test_helper"

class AgentAPI::V1::Executors::ExecutorContextsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @application = executors(:address)
    @application_context = { "root" => "/application" }
    @provider_context = { "root" => "/provider" }
    @credentials = {
      @application.public_id => bearer(create_bound_credential(executor: @application, name: "Application transport").secret),
    }
    @member = create_access_token_fixture(user: @human, name: "Context reader")
    DevModelLane.ensure_enabled!(@account)
  end

  test "an override delivers its captured context through inbox claim extend and detail despite later routing changes" do
    provider, name = provider_route("override")
    call = generated_call(name: name, contexts: {
      @application.public_id => @application_context, provider.public_id => @provider_context,
    })
    assert_equal provider, call.addressed_executor
    assert_context @provider_context, detail(call)

    replacement = register_provider(identifier: "replacement", tools: memory_tools)
    override!(replacement)

    assert_context @provider_context, inbox(provider, call).sole
    assert_equal @provider_context,
      Executors::TaskOperations::Context.executor_context(call, executor: replacement)
    assert_delivery_context @provider_context, call, provider
    assert_empty inbox(replacement, call)
  end

  test "pool viewers see their own captures and the claimant owns every later projection" do
    provider, name = provider_route("pool")
    other = register_provider(identifier: "other", tools: provider_tools(name))
    other_context = { "root" => "/other-provider" }
    call = generated_call(name: name, contexts: {
      @application.public_id => @application_context, provider.public_id => @provider_context,
      other.public_id => other_context,
    })
    assert_nil call.addressed_executor
    assert_context nil, detail(call)
    assert_context @provider_context, inbox(provider, call).sole
    assert_context other_context, inbox(other, call).sole

    assert_delivery_context @provider_context, call, provider
    assert_empty inbox(other, call)
    post agent_api_v1_executor_inbox_claim_path(run_public_id: call.run.public_id, task_key: call.node_key),
      headers: credential(other)
    assert_response :conflict
    assert_equal "already_claimed", response.parsed_body.dig("error", "code")
    assert_equal @provider_context,
      Executors::TaskOperations::Context.executor_context(call.reload, executor: other)
  end

  %w[override pool].each do |route|
    { "missing" => nil, "empty" => {} }.each do |label, captured|
      test "a #{route} provider's #{label} capture never falls back to the application" do
        provider, name = provider_route(route)
        contexts = { @application.public_id => @application_context }
        contexts[provider.public_id] = captured unless captured.nil?
        call = generated_call(name: name, contexts: contexts)

        assert_context captured, inbox(provider, call).sole
        assert_delivery_context captured, call, provider
      end
    end

    test "approval notification does not select the application's context before #{route} delivery" do
      provider, name = provider_route(route)
      call = generated_call(name: name, contexts: {
        @application.public_id => @application_context, provider.public_id => @provider_context,
      }, approval_mode: "ask")
      assert_equal "needs_approval", call.status
      notice = inbox(@application, call).sole
      assert_equal "approval", notice.fetch("kind")
      assert_context nil, notice
      assert_context nil, detail(call)
      assert_empty inbox(provider, call)

      post "#{task_path(call)}/approve", headers: bearer(@member.secret), as: :json
      assert_response :success
      schedule_loop!(call.run)

      assert_context @provider_context, inbox(provider, call).sole
      assert_delivery_context @provider_context, call, provider
    end

    test "denied #{route} approval never turns its notification address into an execution address" do
      provider, name = provider_route(route)
      call = generated_call(name: name, contexts: {
        @application.public_id => @application_context, provider.public_id => @provider_context,
      }, approval_mode: "ask")

      post "#{task_path(call)}/deny", headers: bearer(@member.secret), as: :json, params: { reason: "Declined" }
      assert_response :success
      task = detail(call)
      assert_equal "failed", task.fetch("status")
      assert_context nil, task
    end
  end

  test "approval retains an accepted Runner target's context" do
    context = { "root" => "/runner" }
    call = generated_call(name: "read_file", contexts: {
      @application.public_id => @application_context, suite_runner.public_id => context,
    }, approval_mode: "ask")

    assert_equal "needs_approval", call.status
    assert_equal suite_runner.public_id, call.target_executor_public_id
    assert_context context, inbox(@application, call).sole
    assert_context context, detail(call)
  end

  test "direct application delivery retains its own captured context" do
    announce_tools!(@agent, ["application_work"])
    call = generated_call(name: "application_work", contexts: { @application.public_id => @application_context })

    assert_equal @application, call.addressed_executor
    assert_context @application_context, inbox(@application, call).sole
    assert_delivery_context @application_context, call, @application
  end

  private

    def register_provider(identifier:, tools:)
      connection = connect_runner(manager: users(:owner), registration_identifier: identifier,
        display_name: identifier, assignment_scope: :account_wide, executor_kind: :tool_provider)
      provider = connection.executor_access_token.executor
      announced = provider.announce(services: { "tool_provider" => { "tools" => tools } })
      assert_predicate announced, :accepted?
      @credentials[provider.public_id] = bearer(connection.executor_access_secret)
      provider
    end

    def provider_tools(name)
      [{ "name" => name, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }]
    end

    def memory_tools
      Nexus::ToolRegistry.wire_names_in("nexus.memory").map do |name|
        { "name" => name, "effect_profile" => Nexus::ToolRegistry.effect_profile_for(name) }
      end
    end

    def provider_route(route)
      if route == "override"
        provider = register_provider(identifier: "provider", tools: memory_tools)
        override!(provider)
        [provider, "memory_read"]
      else
        [register_provider(identifier: "provider", tools: provider_tools("net_fetch")), "net_fetch"]
      end
    end

    def override!(provider)
      result = Workspaces::SetToolProviderOverrides.call(workspace: @workspace, by: users(:owner),
        lock_version: @workspace.reload.lock_version, overrides: { "nexus.memory" => provider.public_id })
      assert_equal :updated, result.outcome
    end

    def generated_call(name:, contexts:, approval_mode: "bypass")
      definition = if Nexus::ToolRegistry.kernel_name?(name)
        Nexus::ToolRegistry.function_definition(name)
      else
        { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
      end
      run = seed(model("round", "tools" => [definition], "executor_contexts" => contexts),
        creating_user: @agent, approval_mode: approval_mode)
      started = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @agent))
      assert_predicate started, :accepted?
      schedule_loop!(run)
      run_loop_round!(run, sse_success("working", tool_calls: [
        { id: "context_call", name: name, arguments: { path: "workspace/notes.md" }.to_json },
      ]))
      run.tasks.find_by!(tool_call_id: "context_call")
    end

    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

    def credential(executor)
      @credentials.fetch(executor.public_id)
    end

    def inbox(executor, call)
      get agent_api_v1_executor_inbox_path, headers: credential(executor)
      assert_response :success
      response.parsed_body.fetch("tasks").select do |task|
        task.fetch("run_public_id") == call.run.public_id && task.fetch("task_key") == call.node_key
      end
    end

    def task_path(call)
      "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{call.run.public_id}/tasks/#{call.node_key}"
    end

    def detail(call)
      get task_path(call), headers: bearer(@member.secret)
      assert_response :success
      response.parsed_body.fetch("task")
    end

    def assert_context(expected, task)
      if expected.nil?
        assert_not task.key?("executor_context"), task.inspect
      else
        assert_equal expected, task.fetch("executor_context")
      end
    end

    def assert_delivery_context(expected, call, executor)
      post agent_api_v1_executor_inbox_claim_path(run_public_id: call.run.public_id, task_key: call.node_key),
        headers: credential(executor)
      assert_response :success
      assert_context expected, response.parsed_body.fetch("task")
      token = response.parsed_body.dig("claim", "claim_token")

      post agent_api_v1_executor_inbox_extend_path(run_public_id: call.run.public_id, task_key: call.node_key),
        headers: credential(executor), as: :json, params: { claim_token: token, timeout_ms: 60_000 }
      assert_response :success
      assert_context expected, response.parsed_body.fetch("task")
      assert_context expected, inbox(executor, call).sole
      assert_context expected, detail(call)
    end
end
