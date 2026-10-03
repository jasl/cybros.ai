require "test_helper"

# The SDK consumes the shared contract pack: the
# vocabularies and projection keys it types are asserted against what Nexus
# exports in contracts/nexus/v1, so drift is a test failure here rather than
# a runtime surprise inside an agent. The pack is the source of every
# expected value — nothing below restates a state or key literal.
class ApiWorkspaceContractTest < Minitest::Test
  CONTRACTS_DIR = File.expand_path("../../../../contracts/nexus/v1", __dir__)

  def contract(name)
    JSON.parse(File.read(File.join(CONTRACTS_DIR, name)))
  end

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
  end

  def test_the_workspace_projection_keys_match_the_pack
    pack = contract("workspaces.json")
    basic = CybrosAgent::Api::WorkspaceSummary.members.map(&:to_s)
    full = CybrosAgent::Api::Workspace.members.map(&:to_s)

    assert_equal pack.fetch("basic_projection").sort, basic.sort
    assert_equal pack.fetch("full_projection_adds").sort, (full - basic).sort
    assert_equal pack.fetch("pagination").sort,
      (CybrosAgent::Api::Page.members.map(&:to_s) - ["items"]).sort
  end

  # THE OVERRIDE OPT-IN AGAINST THE PACK: the request fixture
  # names exactly the overridable namespaces, the SDK's PUT sends that
  # fixture's body byte for byte, the three refusals are 422s the pack
  # lists, and an entry parses through the real Full path.
  def test_the_tool_provider_override_request_and_refusals_match_the_pack
    pack = contract("workspaces.json")
    request = pack.fetch("valid_tool_provider_overrides_request")
    command = request.fetch("tool_provider_overrides")
    provider_public_id = command.fetch("overrides").fetch("nexus.memory")
    fixture = pack.fetch("valid_full_fixture").fetch("workspace")
    entry = { "provider_public_id" => provider_public_id, "display_name" => "Fixture provider",
              "assignment_scope" => "account_wide" }

    assert_equal pack.fetch("overridable_namespaces").sort, command.fetch("overrides").keys.sort
    workspace = client([[200, {}, {
      "workspace" => fixture.merge("tool_provider_overrides" => { "nexus.memory" => entry }),
    }]]).workspace(fixture.fetch("public_id")).set_tool_provider_overrides(
      overrides: command.fetch("overrides"), lock_version: command.fetch("lock_version")
    )

    assert_equal request, @transport.requests.fetch(0).fetch(:body)
    assert_equal provider_public_id, workspace.tool_provider_overrides.fetch("nexus.memory").provider_public_id
    assert_equal "Fixture provider", workspace.tool_provider_overrides.fetch("nexus.memory").display_name
    assert_equal({}, client([[200, {}, { "workspace" => fixture }]])
      .workspaces.fetch(fixture.fetch("public_id")).tool_provider_overrides)
    %w[reserved_namespace provider_not_eligible provider_incomplete].each do |code|
      assert_equal 422, pack.fetch("error_statuses").fetch(code)
      assert_includes pack.fetch("error_codes"), code
    end
  end

  def test_the_store_entry_projection_keys_match_the_pack
    pack = contract("store_entries.json")
    basic = CybrosAgent::Api::StoreEntrySummary.members.map(&:to_s)
    full = CybrosAgent::Api::StoreEntry.members.map(&:to_s)

    assert_equal pack.fetch("basic_projection").sort, basic.sort
    assert_equal pack.fetch("full_projection_adds").sort, (full - basic).sort
  end

  def test_the_packs_valid_workspace_fixture_parses_through_the_real_list_path
    pack = contract("workspaces.json")
    fixture = pack.fetch("valid_fixture").fetch("workspace")

    page = client([[200, {}, {
      "workspaces" => [fixture],
      "pagination" => { "next_after" => nil },
    }]]).workspaces.list

    summary = page.items.fetch(0)
    assert_equal fixture.fetch("public_id"), summary.public_id
    assert_equal fixture.fetch("state"), summary.state
    assert_equal fixture.fetch("access_mode"), summary.access_mode
    assert_equal fixture.fetch("lock_version"), summary.lock_version
  end

  # The vocabulary constants inform; the parser does not gate on them. An
  # additive state from a newer Nexus is carried, never a client crash.
  def test_an_unknown_state_is_carried_rather_than_refused
    pack = contract("workspaces.json")
    fixture = pack.fetch("valid_fixture").fetch("workspace")
      .merge("state" => pack.fetch("unknown_state_fixture"))

    page = client([[200, {}, {
      "workspaces" => [fixture],
      "pagination" => { "next_after" => nil },
    }]]).workspaces.list

    assert_equal pack.fetch("unknown_state_fixture"), page.items.fetch(0).state,
      "the parser never gates on the states vocabulary: a state the pack does not list is carried"
    refute_includes pack.fetch("states"), pack.fetch("unknown_state_fixture")
  end

  def test_the_packs_valid_store_entry_fixture_parses_through_the_real_fetch_path
    pack = contract("store_entries.json")
    fixture = pack.fetch("valid_fixture").fetch("store_entry")

    entry = client([[200, {}, { "store_entry" => fixture }]])
      .workspace("019f0000-0000-7000-8000-000000000101")
      .store_entries
      .fetch(fixture.fetch("public_id"))

    assert_equal fixture.fetch("namespace"), entry.namespace
    assert_equal fixture.fetch("key"), entry.key
    assert_nil entry.value, "the pack's stored JSON null must survive as nil, not be dropped"
  end
end
