require "test_helper"

class API::V1::AgentResourcesTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
    @connection = connect_agent_session(steward: @owner, agent_identifier: "resources.application")
    @agent = @connection.access_token.user
    @named = Users::DeclareNamedAgent.call(caller: @agent, name: "reviewer", scope: "steward",
      description: "Review changes", configuration: { prompt_mechanism: "default", approval_mode: "bypass",
        tool_definitions: [], approval_rules: nil, prompt_template: nil, compaction_policy: nil, default_model: nil,
        kernel_tools: ["nexus.memory.read"] }).user
    post api_v1_session_path, params: { email: @owner.identity.email, password: "password" }, as: :json
    assert_response :created
    @headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
  end

  test "Human reads paired and named identities while credential doors remain independent only" do
    get "/api/v1/agents", headers: @headers
    assert_response :success
    rows = response.parsed_body.fetch("agents")
    assert_includes rows.map { |row| row.fetch("public_id") }, @named.public_id
    assert_nil rows.find { |row| row.fetch("public_id") == @agent.public_id }.fetch("named_agent_scope")
    row = rows.find { |item| item.fetch("public_id") == @named.public_id }
    assert_equal "steward", row.fetch("named_agent_scope")
    assert_equal @agent.public_id, row.fetch("derived_from_public_id")

    get agent_path_for(@named), headers: @headers
    assert_response :success
    assert_equal @named.public_id, response.parsed_body.dig("agent", "public_id")
    %w[api_keys executor/api_keys private_runners].each do |suffix|
      get "#{agent_path_for(@named)}/#{suffix}", headers: @headers
      assert_response :not_found
    end
  end

  test "configuration reads the named Agent's own declaration and documents even when its model is unavailable" do
    @agent.update!(default_model: "dev/mock-text")
    @named.update!(default_model: "retired/unavailable", memory_context_limit: { "bindings" => [
      { "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read" },
    ] })
    write_document(@agent, "system_prompt", "Parent prompt")
    write_document(@named, "system_prompt", "Own prompt")
    write_document(@named, "summarizer", "Own summary")
    attributes = @named.reload.attributes

    get "#{agent_path_for(@named)}/configuration", headers: @headers

    assert_response :success
    body = response.parsed_body
    assert_equal "retired/unavailable", body.dig("configuration", "default_model")
    assert_equal @named.memory_context_limit, body.dig("configuration", "memory_context_limit")
    documents = body.fetch("prompt_documents").index_by { |row| row.fetch("slot") }
    assert_equal "Own prompt", documents.fetch("system_prompt").fetch("content")
    assert_equal "Own summary", documents.fetch("summarizer").fetch("content")
    assert_equal 1, documents.fetch("system_prompt").fetch("version")
    assert_equal "Own prompt".bytesize, documents.fetch("system_prompt").fetch("bytesize")
    assert body.fetch("agent_updated_at")
    assert body.fetch("measured_at")
    assert_not_includes response.body, "Parent prompt"
    assert_equal attributes, @named.reload.attributes
  end

  test "shared application connection is independent of own registration and follows the live ownership boundary" do
    address = @connection.executor_access_token.executor
    get agent_path_for(@named), headers: @headers
    assert_response :success
    shared = response.parsed_body.dig("agent", "application_connection")
    assert_equal address.public_id, shared.fetch("executor_public_id")
    assert_equal @agent.public_id, shared.fetch("owner_agent_public_id")
    assert_equal "ready", shared.fetch("credential_readiness")
    assert_equal "not_yet_seen", shared.fetch("presence")
    assert_nil Executor.address_for(@named)
    assert_not_includes response.body, "credential_epoch"
    assert_not_includes response.body, "secret"

    @agent.change_steward(to: users(:owner))
    get agent_path_for(@named), headers: @headers
    assert_response :success
    assert_nil response.parsed_body.dig("agent", "application_connection")
  end

  test "removed named Agent remains readable but cannot claim the declarer's connection" do
    @named.remove

    get "#{agent_path_for(@named)}/configuration", headers: @headers
    assert_response :success
    assert_equal "removed", response.parsed_body.dig("agent", "status")
    get agent_path_for(@named), headers: @headers
    assert_response :success
    assert_nil response.parsed_body.dig("agent", "application_connection")
  end

  test "configuration conceals another steward's identity even from an administrator" do
    post api_v1_session_path, params: { email: users(:owner).identity.email, password: "password" }, as: :json
    admin_headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
    [@agent, @named].each do |row|
      get "#{agent_path_for(row)}/configuration", headers: admin_headers
      assert_response :not_found
    end
  end

  test "member and executor bearers cannot borrow a browser session on management reads" do
    sign_in_as @owner
    [@connection.access_secret, @connection.executor_access_secret].each do |secret|
      wrong_plane = { "Authorization" => "Bearer #{secret}" }
      get "#{agent_path_for(@agent)}/configuration", headers: wrong_plane
      assert_response :unauthorized
    end
  end

  private

    def agent_path_for(row) = "/api/v1/agents/#{row.public_id}"

    def write_document(agent, slot, content)
      agent.with_lock do
        assert_predicate PromptDocuments::Write.call(anchor: { user: agent }, slot: slot, content: content), :written?
      end
    end
end
