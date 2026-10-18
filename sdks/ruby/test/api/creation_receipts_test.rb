require "test_helper"
require_relative "../support/contract_fixtures"

class ApiCreationReceiptsTest < Minitest::Test
  def test_workspace_creation_keeps_the_receipt_signal_beside_the_resource
    fixture = CybrosAgentTest::ContractFixtures.pack("workspaces.json").fetch("valid_full_fixture")
    client, transport = client_for(fixture)

    created = client.workspaces.create(name: "Notes", idempotency_key: "same-key")
    replayed = client.workspaces.create(name: "Notes", idempotency_key: "same-key")

    refute_predicate created, :replayed?
    assert_predicate replayed, :replayed?
    assert_equal created.workspace, replayed.workspace
    assert_equal fixture.fetch("workspace").fetch("public_id"), created.workspace.public_id
    assert_equal transport.requests[0], transport.requests[1]
  end

  def test_workspace_and_conversation_store_creation_keep_the_replay_signal
    fixture = CybrosAgentTest::ContractFixtures.pack("store_entries.json").fetch("valid_fixture")
    [false, true].each do |conversation|
      client, transport = client_for(fixture)
      workspace = client.workspace("workspace-1")
      store = conversation ? workspace.conversation("conversation-1").store_entries : workspace.store_entries
      fields = { namespace: "notes", key: "saved", value: nil, idempotency_key: "same-key" }

      created = store.create(**fields)
      replayed = store.create(**fields)

      refute_predicate created, :replayed?
      assert_predicate replayed, :replayed?
      assert_equal created.store_entry, replayed.store_entry
      assert_equal fixture.fetch("store_entry").fetch("public_id"), created.store_entry.public_id
      assert_equal transport.requests[0], transport.requests[1]
    end
  end

  def test_profile_store_creation_has_the_same_result_shape_without_a_receipt
    fixture = CybrosAgentTest::ContractFixtures.pack("store_entries.json").fetch("valid_fixture")
    transport = CybrosAgentTest::FakeTransport.new([
      [201, {}, fixture],
      [409, {}, { "error" => { "code" => "key_taken", "message" => "Already exists" } }],
    ])
    store = client(transport).profile.store_entries
    fields = { namespace: "notes", key: "saved", value: nil, idempotency_key: "same-key" }

    created = store.create(**fields)
    refute_predicate created, :replayed?
    assert_equal fixture.fetch("store_entry").fetch("public_id"), created.store_entry.public_id
    error = assert_raises(CybrosAgent::Api::Conflict) { store.create(**fields) }
    assert_equal "key_taken", error.code
    assert_equal 2, transport.requests.length
  end

  private

    def client_for(fixture)
      transport = CybrosAgentTest::FakeTransport.new([
        [201, { "Idempotency-Replayed" => "false" }, fixture],
        [201, { "idempotency-replayed" => "true" }, fixture],
      ])
      [client(transport), transport]
    end

    def client(transport)
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "member", transport: transport)
    end
end
