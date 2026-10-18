require "test_helper"
require_relative "../support/contract_fixtures"

# Reused grammars still have separate owning paths. Exercise those scopes
# through their public handles so one host cannot silently point at another.
class ApiScopedResourceContractTest < Minitest::Test
  def pack(name) = CybrosAgentTest::ContractFixtures.pack("#{name}.json")

  def client(script, platform: false)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    klass = platform ? CybrosAgent::PlatformClient : CybrosAgent::Client
    klass.new(base_url: "https://nexus.example", credential: "fixture-token", transport: @transport)
  end

  def test_profile_and_conversation_store_mutations_keep_their_host_and_version
    selectors = {
      "/agent_api/v1/profile/store_entries" => ->(api) { api.profile.store_entries },
      "/agent_api/v1/workspaces/workspace/conversations/conversation/store_entries" =>
        ->(api) { api.workspace("workspace").conversation("conversation").store_entries },
    }
    selectors.each do |path, select|
      body = pack("store_entries").fetch("valid_fixture")
      store = select.call(client([[200, {}, body], [200, {}, body], [204, {}, nil]]))
      assert_nil store.fetch("entry/one").value
      store.update("entry/one", value: nil, lock_version: 3)
      assert_nil store.delete("entry/one", lock_version: 4)
      assert_equal ["#{path}/entry%2Fone"] * 3, @transport.requests.map { |request| request.fetch(:path) }
      assert_equal %i[get patch delete], @transport.requests.map { |request| request.fetch(:method) }
      assert_equal({ "store_entry" => { "value" => nil, "lock_version" => 3 } }, @transport.requests.fetch(1).fetch(:body))
      assert_equal({ "lock_version" => 4 }, @transport.requests.last.fetch(:params))
    end
  end

  def test_each_memory_owner_sends_conditional_edits_and_scoped_literal_search
    selectors = {
      "/agent_api/v1/profile/memory" => ->(api) { api.profile.memory },
      "/agent_api/v1/profile/agents/reviewer/memory" => ->(api) { api.profile.agents.memory(name: "reviewer") },
      "/agent_api/v1/workspaces/workspace/memory" => ->(api) { api.workspace("workspace").memory },
    }
    selectors.each do |path, select|
      fixture = pack("memory_documents")
      memory = select.call(client([[200, {}, fixture.fetch("valid_list_fixture")],
        [200, {}, fixture.fetch("valid_grep_fixture")], [200, {}, fixture.fetch("valid_fixture")], [204, {}, nil]]))
      refute_empty memory.list
      memory.grep(pattern: "literal[", ignore_case: true)
      memory.edit(path: "workspace/notes", old_text: "before", new_text: "after", expected_public_id: "version", expected_lock_version: 2)
      assert_nil memory.delete("workspace/notes", expected_public_id: "version", expected_lock_version: 3)
      assert_equal [path, "#{path}/grep", "#{path}/edit", "#{path}/delete"], @transport.requests.map { |request| request.fetch(:path) }
      assert_equal "literal[", @transport.requests.fetch(1).dig(:body, "memory", "pattern")
      assert_equal "version", @transport.requests.fetch(2).dig(:body, "memory", "expected_public_id")
      assert_equal 3, @transport.requests.last.dig(:body, "memory", "expected_lock_version")
    end
  end

  def test_platform_mcp_reads_the_owner_projection_on_the_platform_plane
    fixture = pack("mcp_connections").fetch("owner_fixture")
    row = fixture.fetch("mcp_connection")
    connections = client([[200, {}, { "mcp_connections" => [row], "pagination" => { "next_after" => nil } }],
      [200, {}, fixture]], platform: true).mcp_connections
    assert_equal row.fetch("public_id"), connections.list.items.first.public_id
    assert_equal row.fetch("public_id"), connections.fetch("connection").public_id
    assert_equal ["/api/v1/mcp_connections", "/api/v1/mcp_connections/connection"], @transport.requests.map { |request| request.fetch(:path) }
  end

  def test_conversation_delete_commands_and_standalone_resume_have_distinct_owners
    api = client([[204, {}, nil], [204, {}, nil], [200, {}, pack("runs").fetch("valid_request_run_fixture")]])
    conversation = api.workspace("workspace").conversation("conversation")
    assert_nil conversation.inputs.delete("input")
    assert_nil conversation.turns.delete("turn")
    result = api.workspace("workspace").run("run").resume
    assert_equal pack("runs").dig("valid_request_run_fixture", "run", "public_id"), result.public_id
    assert_equal [
      "/agent_api/v1/workspaces/workspace/conversations/conversation/inputs/input",
      "/agent_api/v1/workspaces/workspace/conversations/conversation/turns/turn",
      "/agent_api/v1/workspaces/workspace/runs/run/resume",
    ], @transport.requests.map { |request| request.fetch(:path) }
    assert_equal %i[delete delete post], @transport.requests.map { |request| request.fetch(:method) }
  end
end
