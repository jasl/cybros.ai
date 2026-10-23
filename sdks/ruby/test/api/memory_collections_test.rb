require "test_helper"
require_relative "../support/contract_fixtures"

class ApiMemoryCollectionsTest < Minitest::Test
  def pack = CybrosAgentTest::ContractFixtures.pack("memory_collections.json")

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "https://nexus.example", credential: "fixture-token", transport: @transport)
  end

  def test_authorized_owner_handles_create_and_page_but_address_existing_collections_by_uuid
    owners = {
      "/agent_api/v1/profile/memory_collections" => ->(api) { api.profile.memory_collections },
      "/agent_api/v1/profile/agents/reviewer/memory_collections" => ->(api) { api.profile.agents.memory_collections(name: "reviewer") },
      "/agent_api/v1/workspaces/workspace/memory_collections" => ->(api) { api.workspace("workspace").memory_collections },
      "/agent_api/v1/workspaces/workspace/conversations/conversation/memory_collections" => ->(api) { api.workspace("workspace").conversation("conversation").memory_collections },
    }
    owners.each do |path, select|
      collections = select.call(client([[200, {}, pack.fetch("valid_list_fixture")], [201, {}, pack.fetch("valid_fixture")]]))
      page = collections.list(after: "cursor", limit: 7)
      row = collections.create(name: "Notes", description: "References")
      assert_equal page.items.first.public_id, row.public_id
      assert_nil page.next_after
      assert_equal [path, path], @transport.requests.map { |request| request.fetch(:path) }
      assert_equal({ "after" => "cursor", "limit" => 7 }, @transport.requests.first.fetch(:params))
      assert_equal({ "memory_collection" => { "name" => "Notes", "description" => "References", "default" => false } }, @transport.requests.last.fetch(:body))
      assert_equal "/agent_api/v1/memory_collections/#{row.public_id}/documents", collections.documents(row.public_id).path
    end
  end

  def test_metadata_and_lifecycle_commands_carry_the_exact_metadata_version
    row = pack.fetch("valid_fixture").fetch("memory_collection")
    uuid = row.fetch("public_id")
    api = client([[200, {}, pack.fetch("valid_list_fixture")]] + Array.new(4) { [200, {}, pack.fetch("valid_fixture")] } + [[204, {}, nil]])
    collections = api.memory_collections
    assert_equal uuid, collections.list.items.first.public_id
    assert_equal row.transform_keys(&:to_sym), collections.fetch(uuid).to_h
    collections.update(uuid, name: "Revised", lock_version: 2)
    collections.archive(uuid, lock_version: 3)
    collections.restore(uuid, lock_version: 4)
    assert_nil collections.delete(uuid, lock_version: 5)
    assert_equal %i[get get patch post post delete], @transport.requests.map { |request| request.fetch(:method) }
    assert_equal [2, 3, 4, 5], @transport.requests.drop(2).map { |request| request.dig(:body, "memory_collection", "lock_version") }
    assert_equal ["", "/#{uuid}", "/#{uuid}", "/#{uuid}/archive", "/#{uuid}/restore", "/#{uuid}"],
      @transport.requests.map { |request| request.fetch(:path).delete_prefix("/agent_api/v1/memory_collections") }
  end

  def test_speaker_default_creation_is_explicit_and_conflicts_are_not_retried
    collections = client([[200, {}, pack.fetch("valid_fixture")]]).profile.memory_collections
    collections.create(speaker_public_id: "speaker", default: true)
    assert_equal({ "memory_collection" => { "speaker_public_id" => "speaker", "default" => true } }, @transport.requests.last.fetch(:body))

    collections = client([[409, {}, { "error" => { "code" => "stale_object", "message" => "Changed" } }]]).memory_collections
    assert_raises(CybrosAgent::Api::Conflict) { collections.archive("collection", lock_version: 2) }
    assert_equal 1, @transport.requests.length
  end

  def test_default_discovery_is_read_only_and_blank_descriptions_are_valid
    body = pack.fetch("valid_list_fixture")
    body.fetch("memory_collections").first["description"] = ""
    body.fetch("memory_collections").first["name"] = ""
    collections = client([[200, {}, body]]).profile.memory_collections
    row = collections.list(default: true, speaker_public_id: "speaker").items.first
    assert_equal ["", ""], [row.name, row.description]
    assert_equal :get, @transport.requests.first.fetch(:method)
    assert_equal({ "default" => true, "speaker_public_id" => "speaker" }, @transport.requests.first.fetch(:params))

    nullable = pack.fetch("valid_default_fixture")
    row = client([[200, {}, nullable]]).memory_collections.fetch("collection")
    assert_nil row.name
    assert_nil row.description

    [7, {}].each do |invalid|
      body.fetch("memory_collections").first["description"] = invalid
      assert_raises(CybrosAgent::Api::MalformedResponse) { client([[200, {}, body]]).memory_collections.list }
    end
  end

  def test_context_create_pins_the_collection_even_when_the_path_is_absent
    uuid = pack.dig("valid_fixture", "memory_collection", "public_id")
    bindings = { "bindings" => [{ "name" => "notes", "source" => { "collection_public_id" => uuid },
      "scope" => "workspace", "access" => "read_write", "collection_public_id" => uuid,
      "owner_public_id" => "workspace", "speaker_public_id" => nil, "state" => "active" }] }
    api = client([[200, {}, { "memory" => [], "memory_context" => bindings }],
      [409, {}, { "error" => { "code" => "stale_object", "message" => "Binding changed" } }]])
    memory = api.workspace("workspace").conversation("conversation").memory
    assert_equal bindings, memory.bindings
    assert_raises(CybrosAgent::Api::Conflict) do
      memory.write("notes/new.md", "old proposal", expected_collection_public_id: uuid, expected_public_id: nil, expected_lock_version: nil)
    end
    assert_equal({ "path" => "notes/new.md", "content" => "old proposal", "expected_collection_public_id" => uuid,
      "expected_public_id" => nil, "expected_lock_version" => nil }, @transport.requests.last.dig(:body, "memory"))
    assert_equal 2, @transport.requests.length
  end
end
