require "test_helper"
require_relative "support/contract_fixtures"

class PlatformAgentsTest < Minitest::Test
  def pack = CybrosAgentTest::ContractFixtures.pack("platform_agents.json")

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "platform-key", transport: @transport)
  end

  def test_stewarded_agents_have_typed_management_and_lifecycle_operations
    agents = client([[201, {}, pack.fetch("valid_agent_fixture")], [200, {}, pack.fetch("valid_agents_fixture")],
      [200, {}, pack.fetch("valid_agent_detail_fixture")]] +
      Array.new(3) { [200, {}, pack.fetch("valid_agent_fixture")] }).agents
    created = agents.create(display_name: "Fixture agent")
    assert_equal created, agents.list(after: "cursor", limit: 2).items.first
    agent = agents.agent("agent/one")
    detail = agent.fetch
    assert_instance_of CybrosAgent::Platform::AgentDetail, detail
    assert_equal created.public_id, detail.public_id
    assert_equal created.public_id, detail.application_connection.owner_agent_public_id
    assert_equal "ready", detail.application_connection.credential_readiness
    assert_nil created.named_agent_scope
    assert_nil created.description
    assert_nil created.derived_from_public_id
    assert_equal created, agent.revoke_connection
    assert_equal created, agent.remove
    assert_equal created, agent.restore

    assert_equal [:post, :get, :get, :post, :post, :post], @transport.requests.map { |request| request.fetch(:method) }
    assert_equal({ "agent" => { "display_name" => "Fixture agent" } }, @transport.requests.first.fetch(:body))
    assert_equal({ "after" => "cursor", "limit" => 2 }, @transport.requests.fetch(1).fetch(:params))
    assert_equal "/api/v1/agents/agent%2Fone", @transport.requests.fetch(2).fetch(:path)
    assert_equal %w[connection_revocation removal restoration], @transport.requests.last(3).map { |request| request.fetch(:path).split("/").last }
  end

  def test_configuration_reuses_typed_declaration_and_prompt_documents_with_independent_timestamps
    fixture = pack.fetch("valid_agent_configuration_fixture")
    snapshot = client([[200, {}, fixture]]).agents.agent("agent/one").configuration

    assert_instance_of CybrosAgent::Platform::AgentConfigurationSnapshot, snapshot
    assert_instance_of CybrosAgent::Platform::Agent, snapshot.agent
    assert_instance_of CybrosAgent::Api::AgentConfiguration, snapshot.configuration
    assert_equal fixture.dig("configuration", "memory_context_limit"), snapshot.configuration.memory_context_limit
    assert_equal fixture.dig("configuration", "fallback_models"), snapshot.configuration.fallback_models
    assert_nil snapshot.configuration.runner_tool_names
    document = snapshot.prompt_documents.first
    assert_instance_of CybrosAgent::Api::PromptDocument, document
    assert_equal fixture.dig("prompt_documents", 0, "content"), document.content
    assert_equal fixture.dig("prompt_documents", 0, "version"), document.version
    assert_equal fixture.fetch("agent_updated_at"), snapshot.agent_updated_at
    assert_equal fixture.fetch("measured_at"), snapshot.measured_at
    assert_equal "/api/v1/agents/agent%2Fone/configuration", @transport.requests.last.fetch(:path)
    assert_equal "platform-key", @transport.requests.last.fetch(:credential)
  end

  def test_named_identity_retains_its_declarer_and_nullable_shared_connection
    fixture = pack.fetch("valid_agent_detail_fixture")
    fixture.fetch("agent").merge!("named_agent_scope" => "steward", "description" => "Reviews changes",
      "derived_from_public_id" => "declarer", "application_connection" => nil)
    detail = client([[200, {}, fixture]]).agents.agent("named").fetch

    assert_equal "steward", detail.named_agent_scope
    assert_equal "Reviews changes", detail.description
    assert_equal "declarer", detail.derived_from_public_id
    assert_nil detail.application_connection
  end

  def test_both_key_resources_keep_their_plane_and_show_secrets_only_once
    scopes = {
      "member" => [->(agent) { agent.api_keys }, "/api/v1/agents/agent/api_keys"],
      "executor" => [->(agent) { agent.executor_api_keys }, "/api/v1/agents/agent/executor/api_keys"],
    }
    scopes.each do |name, (select, path)|
      kind = name == "member" ? "member" : "executor"
      agent = client([[201, {}, pack.fetch("valid_#{kind}_key_grant_fixture")],
        [200, {}, pack.fetch("valid_#{kind}_keys_fixture")], [204, {}, nil]]).agents.agent("agent")
      keys = select.call(agent)
      grant = keys.create(name: "application", note: nil)
      assert_equal grant.api_key, keys.list.items.first
      assert_nil keys.revoke("key/one")
      assert_equal [path, path, "#{path}/key%2Fone/revocation"], @transport.requests.map { |request| request.fetch(:path) }
      assert_equal [:post, :get, :post], @transport.requests.map { |request| request.fetch(:method) }
      assert_equal({ "api_key" => { "name" => "application", "note" => nil } }, @transport.requests.first.fetch(:body))
      assert_equal "platform-key", @transport.requests.first.fetch(:credential)
      refute_includes grant.inspect, grant.secret
    end
  end

  def test_private_runner_management_is_not_part_of_an_agent
    refute_respond_to client([]).agents.agent("agent"), :private_runners
  end

  def test_future_statuses_are_carried_but_a_key_cannot_change_credential_planes
    agent = client([[200, {}, pack.fetch("unknown_agent_status_fixture")]]).agents.agent("agent").fetch
    assert_equal "zz_unknown_value", agent.status
    keys = client([[201, {}, pack.fetch("unknown_key_plane_fixture")]]).agents.agent("agent").api_keys
    assert_raises(CybrosAgent::Api::MalformedResponse) { keys.create(name: "application") }
    assert_equal({ "api_key" => { "name" => "application" } }, @transport.requests.first.fetch(:body))
    assert_equal 1, @transport.requests.length
  end

  def test_key_revocation_requires_the_documented_empty_success
    keys = client([[200, {}, {}]]).agents.agent("agent").api_keys
    assert_raises(CybrosAgent::Api::MalformedResponse) { keys.revoke("key") }
  end
end
