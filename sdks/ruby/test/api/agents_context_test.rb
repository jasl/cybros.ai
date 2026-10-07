require "test_helper"
require_relative "../support/contract_fixtures"

# THE CALLER'S NAMED DEFINITIONS (named sub-agents): the
# three verbs against the presenter-rendered fixture — the door's paths
# and methods, the whole-replacement body, the row shape read back with
# its configuration block, and the kernel's refusals typed.
class ApiAgentsContextTest < Minitest::Test
  PATH = "/agent_api/v1/profile/agents".freeze

  def fixture = CybrosAgentTest::ContractFixtures.pack("profiles.json").fetch("named_agents_fixture")
  def reviewer = fixture.fetch("agents").find { |row| row.fetch("name") == "reviewer" }

  def agents(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).profile.agents
  end

  def request = @transport.requests.fetch(0)

  def test_list_reads_the_listing_as_named_agents_with_their_configuration
    rows = agents([[200, {}, fixture]]).list

    assert_equal PATH, request.fetch(:path)
    assert_equal :get, request.fetch(:method)
    assert_equal %w[docs reviewer], rows.map(&:name)
    docs, reviewer = rows
    assert_predicate docs, :published?
    assert_predicate reviewer, :instance?
    assert_equal "rho.7f3a9c1e/reviewer", reviewer.agent_identifier
    assert_equal "reviewer", reviewer.handle
    assert_equal "01900000-0000-7000-8000-000000000020", reviewer.derived_from_public_id
    assert_equal "01900000-0000-7000-8000-000000000003", reviewer.steward_public_id
    assert_equal "agent", reviewer.kind
    assert_match(/Reviews a diff/, reviewer.description)
    configuration = reviewer.configuration
    assert_instance_of CybrosAgent::Api::AgentConfiguration, configuration
    assert_equal "bypass", configuration.approval_mode
    assert_equal "dev/mock-text", configuration.default_model
    assert_equal({ "mode" => "kernel" }, configuration.compaction_policy)
    assert_predicate configuration.tool_definitions, :frozen?, "a snapshot, never a live handle"
    assert_equal [], configuration.kernel_tools
    assert_equal [], configuration.runner_executor_public_ids
    assert_nil configuration.runner_tool_names
    assert_equal [], docs.configuration.tool_definitions
    assert_equal [], docs.configuration.runner_tool_names
    assert_nil docs.configuration.default_model
  end

  def test_declare_puts_the_whole_definition_by_name_and_reads_the_row_back_on_201_or_200
    configuration = reviewer.fetch("configuration")
    row = agents([[201, {}, { "agent" => reviewer }]]).declare(
      name: "reviewer", scope: "instance", description: reviewer.fetch("description"),
      system_prompt: "You are a reviewer.", configuration: configuration.transform_keys(&:to_sym)
    )

    assert_equal "#{PATH}/reviewer", request.fetch(:path)
    assert_equal :put, request.fetch(:method)
    body = request.fetch(:body)
    assert_equal "instance", body.fetch("scope")
    assert_equal reviewer.fetch("description"), body.fetch("description")
    assert_nil body.fetch("display_name"), "the name when absent: the kernel's default, sent as nil"
    assert_equal "You are a reviewer.", body.fetch("system_prompt")
    assert_equal configuration, body.fetch("configuration"), "the whole configuration, string-keyed, as sent"
    assert_equal "reviewer", row.name
    assert_predicate row, :instance?

    published = agents([[200, {}, { "agent" => reviewer.merge("scope" => "steward") }]]).declare(
      name: "reviewer", scope: "steward", description: "Reviews.", display_name: "The reviewer",
      configuration: configuration
    )
    assert_predicate published, :published?
    assert_equal "The reviewer", request.fetch(:body).fetch("display_name")
    assert_nil request.fetch(:body).fetch("system_prompt"), "nil deletes the slot"
  end

  def test_named_definitions_preserve_tool_sources_and_runner_candidate_order
    sources = {
      "kernel_tools" => ["nexus.graph.delegate_task"],
      "runner_executor_public_ids" => ["01900000-0000-7000-8000-000000000052", "01900000-0000-7000-8000-000000000051"],
      "runner_tool_names" => ["read"],
    }
    configuration = reviewer.fetch("configuration").merge(sources)
    row = agents([[200, {}, { "agent" => reviewer.merge("configuration" => configuration) }]]).declare(
      name: "reviewer", scope: "instance", description: "Reviews.", configuration: configuration.transform_keys(&:to_sym)
    )

    sources.each do |name, value|
      assert_equal value, request.fetch(:body).fetch("configuration").fetch(name)
      assert_equal value, row.configuration.public_send(name)
      assert_predicate row.configuration.public_send(name), :frozen?
    end
  end

  def test_remove_deletes_by_name_and_answers_nothing
    assert_nil agents([[204, {}, nil]]).remove(name: "reviewer")
    assert_equal "#{PATH}/reviewer", request.fetch(:path)
    assert_equal :delete, request.fetch(:method)
    assert_raises(ArgumentError) { agents([]).remove(name: "") }
  end

  def test_the_kernels_refusals_cross_typed
    error = { "error" => { "code" => "not_agent", "message" => "Only an Agent declares a configuration" } }
    assert_raises(CybrosAgent::Api::Forbidden) { agents([[403, {}, error]]).list }
    taken = { "error" => { "code" => "identifier_taken", "message" => "A paired program holds this identifier" } }
    conflict = assert_raises(CybrosAgent::Api::Conflict) do
      agents([[409, {}, taken]]).declare(name: "reviewer", scope: "instance", description: "x",
        configuration: reviewer.fetch("configuration"))
    end
    assert_equal "identifier_taken", conflict.code
    assert_raises(CybrosAgent::Api::NotFound) { agents([[404, {}, { "error" => { "code" => "not_found", "message" => "" } }]]).remove(name: "gone") }
  end

  def test_a_row_missing_its_scope_or_configuration_is_malformed
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      agents([[200, {}, { "agents" => [reviewer.except("scope")] }]]).list
    end
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      agents([[200, {}, { "agents" => [reviewer.except("configuration")] }]]).list
    end
  end
end
