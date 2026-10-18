require "test_helper"

class McpConnectionTest < ActiveSupport::TestCase
  setup do
    @connection = mcp_connections(:notes)
    @agent = users(:agent)
    @owner = users(:member)
    assert_equal :changed, @agent.change_steward(to: @owner)
  end

  test "the owner's Agents share the connection and only current catalog tools are available" do
    assert @connection.tool_available?(agent: @agent, name: "search")
    assert_not @connection.tool_available?(agent: @agent, name: "delete")
    assert_not @connection.usable_by?(@owner)

    sibling = @owner.stewarded_agents.create!(account: accounts(:cybros), kind: :agent, role: :member,
      display_name: "Other application", agent_identifier: "other-mcp-application")
    assert @connection.usable_by?(sibling)

    foreign = users(:owner).stewarded_agents.create!(account: accounts(:cybros), kind: :agent, role: :member,
      display_name: "Another Human's application", agent_identifier: "foreign-mcp-application")
    assert_not @connection.usable_by?(foreign)
  end

  test "suspension masks access and reactivation restores an enabled connection" do
    assert_equal :suspended, @owner.suspend
    assert_not @connection.reload.usable_by?(@agent)
    assert @connection.enabled?

    assert_equal :reactivated, @owner.reactivate
    assert @connection.reload.usable_by?(@agent)
  end

  test "Human removal disables owned connections and restore does not enable them" do
    version = @connection.lock_version
    assert_equal :removed, @owner.remove
    assert_not @connection.reload.enabled?
    assert_operator @connection.lock_version, :>, version
    assert_equal :restored, @owner.restore
    assert_not @connection.reload.usable_by?(@agent)
  end

  test "steward transfer derives current access without moving the connection or retaining a grant" do
    sibling = @owner.stewarded_agents.create!(account: accounts(:cybros), kind: :agent, role: :member,
      display_name: "Sibling", agent_identifier: "sibling-mcp-application")
    assert_equal :changed, @agent.change_steward(to: users(:owner))
    assert_not @connection.usable_by?(@agent)
    assert @connection.usable_by?(sibling)
    assert_equal @owner.id, @connection.reload.owner_id

    assert_equal :changed, @agent.change_steward(to: @owner)
    assert @connection.usable_by?(@agent)
  end

  test "selecting the same steward retains connection access" do
    assert_equal :changed, @agent.change_steward(to: @owner)
    assert @connection.reload.usable_by?(@agent)
  end

  test "removing and restoring an Agent rechecks its current eligibility" do
    assert_equal :removed, @agent.remove
    assert_not @connection.usable_by?(@agent)
    assert_equal :restored, @agent.restore
    assert @connection.reload.usable_by?(@agent)
  end

  test "credentials are encrypted and clearing cannot be undone by enablement" do
    connection = @owner.mcp_connections.build(name: "Private notes", endpoint_url: "https://private.example.test/mcp",
      auth_type: "bearer", bearer_token: "fixture-private-token")
    assert connection.save_owned.success?
    assert connection.credential_configured?
    assert_not_includes connection.reload.bearer_token_before_type_cast, "fixture-private-token"
    assert connection.usable_by?(@agent)

    assert connection.set_credential(bearer_token: nil, expected_lock_version: connection.lock_version).success?
    assert_not connection.credential_configured?
    assert connection.revise(attributes: { enabled: true }, expected_lock_version: connection.lock_version).success?
    assert_not connection.usable_by?(@agent)
    assert_nil connection.reload.bearer_token
  end

  test "configuration edits reject a stale version without changing the row" do
    previous = @connection.lock_version
    assert @connection.revise(attributes: { name: "Renamed" }, expected_lock_version: previous).success?
    result = @connection.revise(attributes: { enabled: false }, expected_lock_version: previous)
    assert_equal :stale_object, result.outcome
    assert @connection.reload.enabled?
    assert_equal "Renamed", @connection.name
  end

  test "catalog replacement changes tool availability without another selection gate" do
    @connection.update!(catalog: [{ "name" => "delete", "input_schema" => { "type" => "object" } }])
    assert @connection.tool_available?(agent: @agent, name: "delete")
    assert_not @connection.tool_available?(agent: @agent, name: "search")
  end

  test "a service without authentication refuses the credential command" do
    assert_equal :credential_not_applicable,
      @connection.set_credential(bearer_token: nil, expected_lock_version: @connection.lock_version).outcome
  end

  test "endpoint identity is immutable and malformed credential headers fail validation" do
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @connection.endpoint_url = "https://other.example.test/mcp" }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @connection.auth_type = "bearer" }

    ["file:///tmp/tool", "https://user:password@notes.example.test/mcp", "https://notes.example.test/mcp#fragment"].each do |url|
      connection = @owner.mcp_connections.build(name: "Invalid", endpoint_url: url, auth_type: "none")
      assert_not connection.valid?
      assert connection.errors.added?(:endpoint_url, :invalid)
    end
    connection = @owner.mcp_connections.build(name: "Invalid", endpoint_url: "https://notes.example.test/mcp", auth_type: "bearer",
      bearer_token: "token\r\nInjected: value")
    assert_not connection.valid?
    assert connection.errors.added?(:bearer_token, :invalid)
  end
end
