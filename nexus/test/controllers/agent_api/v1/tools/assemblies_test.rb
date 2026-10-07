require "test_helper"

class AgentAPI::V1::Tools::AssembliesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PATH = "/agent_api/v1/tools/assembly".freeze
  READ = {
    "name" => "read", "description" => "Read a local file",
    "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    "input_schema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } },
      "required" => ["path"], "additionalProperties" => false },
  }.freeze

  setup do
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @secret = connection.access_secret
    @transport_secret = connection.executor_access_secret
    @runner_a = runner("assembly-local", tools: [READ])
    @runner_b = runner("assembly-build", tools: [READ.merge("name" => "build_read")])
    @agent.update!(approval_mode: "bypass", kernel_tools: ["nexus.memory.read"],
      runner_executor_public_ids: [@runner_b.public_id, @runner_a.public_id])
  end

  test "the profile contributes its tools and only the selected Runner imports schemas" do
    assemble(default_runner_executor_public_id: @runner_a.public_id)

    assert_response :success
    body = response.parsed_body
    definitions = body.fetch("tool_definitions")
    assert_equal %w[memory_read read], Nexus::ToolDeclarations.names(definitions)
    imported = definitions.find { |entry| entry.dig("function", "name") == "read" }
    assert_equal READ.fetch("input_schema"), imported.dig("function", "parameters")
    assert_equal({ "kind" => "runner", "runner_executor_public_id" => @runner_a.public_id, "tool_name" => "read" },
      imported.fetch("route"))
    assert_equal true, imported.fetch("defer_loading")
    environment = body.fetch("environment")
    assert_equal @runner_a.public_id, environment.fetch("default_runner_executor_public_id")
    assert_equal [@runner_a.public_id], environment.fetch("executors").map { |row| row.fetch("runner_executor_public_id") }
    assert_equal [@runner_b.public_id, @runner_a.public_id], environment.fetch("runner_candidates")
      .map { |row| row.fetch("runner_executor_public_id") }
    assert_equal @runner_a.environment, environment.fetch("executors").sole.fetch("environment")
    assert_nil @runner_a.presence_connection_id, "socket presence does not gate assembly"
  end

  test "the assembly response matches the shared SDK contract fixture" do
    fixture = Nexus::Contract.pack.fetch("tools.json").fetch("valid_assembly_fixture")
    executor = fixture.fetch("environment").fetch("executors").sole
    definition = fixture.fetch("tool_definitions").sole.fetch("function")
    @runner_a.update!(display_name: executor.fetch("display_name"))
    announced = @runner_a.announce(tools: [{
      "name" => definition.fetch("name"), "description" => definition.fetch("description"),
      "input_schema" => definition.fetch("parameters"), "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }], environment: executor.fetch("environment"))
    assert_predicate announced, :accepted?

    assemble(default_runner_executor_public_id: @runner_a.public_id, configuration: {
      kernel_tools: [], runner_executor_public_ids: [@runner_a.public_id], runner_tool_names: nil,
    })

    assert_response :success
    expected = fixture.deep_transform_values do |value|
      value == executor.fetch("runner_executor_public_id") ? @runner_a.public_id : value
    end
    assert_equal expected, response.parsed_body
  end

  test "null selects no Runner and keeps eligible candidates in declaration order" do
    assemble(default_runner_executor_public_id: nil)

    assert_response :success
    assert_equal ["memory_read"], Nexus::ToolDeclarations.names(response.parsed_body.fetch("tool_definitions"))
    environment = response.parsed_body.fetch("environment")
    assert_nil environment.fetch("default_runner_executor_public_id")
    assert_empty environment.fetch("executors")
    assert_equal [@runner_b.public_id, @runner_a.public_id], environment.fetch("runner_candidates")
      .map { |row| row.fetch("runner_executor_public_id") }
  end

  test "explicit configuration replaces profile sources without persisting it" do
    alias_entry = { "type" => "function", "function" => { "name" => "Remember" }, "canonical" => "nexus.memory.read" }
    configuration = { tool_definitions: [alias_entry], kernel_tools: [],
      runner_executor_public_ids: [], runner_tool_names: nil, approval_mode: "ask", unknown: "ignored" }
    before = @agent.reload.attributes

    assemble(default_runner_executor_public_id: nil, configuration: configuration, unknown: "ignored")

    assert_response :success
    definitions = response.parsed_body.fetch("tool_definitions")
    assert_equal ["Remember"], Nexus::ToolDeclarations.names(definitions)
    assert_equal "nexus.memory.read", definitions.sole.fetch("canonical")
    assert_equal Nexus::ToolDeclarations.render([alias_entry]), definitions
    assert_empty response.parsed_body.fetch("environment").fetch("runner_candidates")
    assert_equal before, @agent.reload.attributes

    assemble(default_runner_executor_public_id: nil, configuration: {})
    assert_response :success
    assert_empty response.parsed_body.fetch("tool_definitions"), "an explicit empty object does not inherit profile tools"
  end

  test "Runner tool allowlists retain only available model tools with nil importing all and empty importing none" do
    configuration = { tool_definitions: [], kernel_tools: [], runner_executor_public_ids: [@runner_a.public_id],
      runner_tool_names: nil }
    assemble(default_runner_executor_public_id: @runner_a.public_id, configuration: configuration)
    assert_response :success
    assert_equal ["read"], Nexus::ToolDeclarations.names(response.parsed_body.fetch("tool_definitions"))

    assemble(default_runner_executor_public_id: @runner_a.public_id, configuration: configuration.merge(runner_tool_names: []))
    assert_response :success
    assert_empty response.parsed_body.fetch("tool_definitions")
    assert_equal @runner_a.public_id, response.parsed_body.dig("environment", "default_runner_executor_public_id")

    assemble(default_runner_executor_public_id: @runner_a.public_id, configuration: configuration.merge(runner_tool_names: ["missing"]))
    assert_response :success
    assert_empty response.parsed_body.fetch("tool_definitions")

    assemble(default_runner_executor_public_id: @runner_a.public_id, configuration: configuration.merge(runner_tool_names: %w[read missing]))
    assert_response :success
    assert_equal ["read"], Nexus::ToolDeclarations.names(response.parsed_body.fetch("tool_definitions"))
  end

  test "source validation reuses canonical names UUID ordering and explicit declaration grammar" do
    [
      { kernel_tools: ["memory_read"] },
      { runner_executor_public_ids: [@runner_a.public_id, @runner_a.public_id] },
      { tool_definitions: [{ "type" => "function", "function" => { "name" => "memory_read", "description" => "Changed" } }] },
    ].each do |configuration|
      assemble(default_runner_executor_public_id: nil, configuration: configuration)
      assert_response :unprocessable_content
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
      assert_includes response.parsed_body.dig("error", "message"), configuration.keys.sole.to_s
    end
  end

  test "unknown or inaccessible Runner selections reveal no environment and candidates are filtered" do
    private_runner = runner("another-person", manager: users(:member), tools: [READ])
    @agent.update!(runner_executor_public_ids: [private_runner.public_id, @runner_a.public_id])
    [private_runner.public_id, SecureRandom.uuid_v7].each do |public_id|
      assemble(default_runner_executor_public_id: public_id)
      assert_response :unprocessable_content
      assert_equal "runner_not_eligible", response.parsed_body.dig("error", "code")
      assert_not response.parsed_body.key?("environment")
      assert_not_includes response.body, private_runner.display_name
    end

    assemble(default_runner_executor_public_id: nil)
    assert_response :success
    assert_equal [@runner_a.public_id], response.parsed_body.dig("environment", "runner_candidates")
      .map { |row| row.fetch("runner_executor_public_id") }
    assert_not_includes response.body, private_runner.display_name
  end

  test "a selected Runner must be declared and keep a ready credential" do
    @agent.update!(runner_executor_public_ids: [@runner_a.public_id])
    assemble(default_runner_executor_public_id: @runner_b.public_id)
    assert_response :unprocessable_content
    assert_equal "runner_not_declared", response.parsed_body.dig("error", "code")

    @runner_a.revoke_credentials
    assemble(default_runner_executor_public_id: @runner_a.public_id)
    assert_response :unprocessable_content
    assert_equal "runner_not_eligible", response.parsed_body.dig("error", "code")
  end

  test "the nullable Runner selector is required and only Agent member credentials are admitted" do
    assemble
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "default_runner_executor_public_id"

    human_secret = create_access_token_fixture(user: users(:owner), name: "Human").secret
    post PATH, params: { default_runner_executor_public_id: nil }, headers: bearer(human_secret), as: :json
    assert_response :forbidden
    assert_equal "not_agent", response.parsed_body.dig("error", "code")

    [nil, @transport_secret].each do |secret|
      post PATH, params: { default_runner_executor_public_id: nil }, headers: secret ? bearer(secret) : {}, as: :json
      assert_response :unauthorized
      assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    end
  end

  test "assembly creates no work jobs mutations or locks after authentication sampling" do
    assemble(default_runner_executor_public_id: @runner_a.public_id)
    assert_response :success
    statements = []
    observer = ->(*, payload) { statements << payload.fetch(:sql) }

    assert_no_enqueued_jobs do
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
        assemble(default_runner_executor_public_id: @runner_a.public_id)
      end
    end

    assert_response :success
    assert_empty statements.grep(/\b(?:INSERT|UPDATE|DELETE|FOR UPDATE|FOR SHARE)\b/i)
  end

  private

    def assemble(**parameters)
      post PATH, params: parameters, headers: bearer(@secret), as: :json
    end

    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

    def runner(identifier, manager: users(:owner), tools:)
      connect_runner(manager: manager, registration_identifier: identifier, display_name: identifier)
        .executor_access_token.task_executor.tap do |executor|
          outcome = executor.announce(tools: tools, environment: { "root" => "/srv/#{identifier}" })
          assert_predicate outcome, :accepted?
        end
    end
end
