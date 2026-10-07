require "test_helper"
require "pp"
require_relative "../support/contract_fixtures"

# A Workspace's nested StoreEntry surface: the
# scoped context, the value-preserving JSON grammar in which a stored null is
# a legal value distinct from omission, and the Full projection whose value
# never reaches a diagnostic.
class ApiStoreEntriesTest < Minitest::Test
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  ENTRIES_PATH = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/store_entries".freeze

  SUMMARY = {
    "public_id" => "019f0000-0000-7000-8000-000000000501",
    "namespace" => "notes",
    "key" => "pinned",
    "lock_version" => 2,
    "created_at" => "2026-07-30T00:00:00Z",
    "updated_at" => "2026-07-30T01:00:00Z",
  }.freeze

  FULL = SUMMARY.merge(
    "value" => { "token" => "rt-stored.secret", "list" => ["sk-cybros-session-v1-stored.secret"] }
  ).freeze

  def entries(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
      .workspace(WORKSPACE_ID)
      .store_entries
  end

  def request
    assert_equal 1, @transport.requests.length
    @transport.requests.fetch(0)
  end

  def test_list_reads_the_nested_collection_with_manual_pagination
    page = entries([[200, {}, {
      "store_entries" => [SUMMARY],
      "pagination" => { "next_after" => "cursor-1" },
    }]]).list(after: "cursor-0", limit: 10)

    assert_equal :get, request.fetch(:method)
    assert_equal ENTRIES_PATH, request.fetch(:path)
    assert_equal({ "after" => "cursor-0", "limit" => 10 }, request.fetch(:params))

    summary = page.items.fetch(0)
    assert_instance_of CybrosAgent::Api::StoreEntrySummary, summary
    assert_equal "notes", summary.namespace
    assert_equal "pinned", summary.key
    assert_equal "cursor-1", page.next_after
    refute_respond_to summary, :value,
      "the Basic projection has no value member, so an omitted value can never read as a stored null"
  end

  def test_list_accepts_null_next_after_as_the_last_page
    page = entries([[200, {}, {
      "store_entries" => [],
      "pagination" => { "next_after" => nil },
    }]]).list

    assert_empty page.items
    assert_nil page.next_after
  end

  def test_list_rejects_pagination_missing_its_required_next_after_member
    context = entries([[200, {}, { "store_entries" => [], "pagination" => {} }]])

    assert_raises(CybrosAgent::Api::MalformedResponse) { context.list }
  end

  def test_create_posts_the_envelope_under_its_client_minted_idempotency_key
    entry = entries([[201, {}, { "store_entry" => FULL }]]).create(
      namespace: "notes", key: "pinned", value: { "token" => "rt-stored.secret" },
      idempotency_key: "key-1"
    )

    assert_equal :post, request.fetch(:method)
    assert_equal ENTRIES_PATH, request.fetch(:path)
    assert_equal "key-1", request.fetch(:headers).fetch("Idempotency-Key")
    assert_equal(
      { "store_entry" => {
        "namespace" => "notes", "key" => "pinned", "value" => { "token" => "rt-stored.secret" },
      } },
      request.fetch(:body)
    )
    assert_instance_of CybrosAgent::Api::StoreEntry, entry
  end

  # JSON null is a legal stored value: value is a required
  # keyword, and an explicit nil MUST travel as null rather than vanish.
  def test_create_sends_an_explicit_nil_value_as_json_null
    entry = entries([[201, {}, { "store_entry" => SUMMARY.merge("value" => nil) }]])
      .create(namespace: "notes", key: "pinned", value: nil, idempotency_key: "key-1")

    body = request.fetch(:body).fetch("store_entry")
    assert body.key?("value"), "the value field must be present even when null"
    assert_nil body.fetch("value")
    assert_nil entry.value
  end

  def test_create_refuses_a_blank_idempotency_key_before_transport
    context = entries([])

    assert_raises(ArgumentError) do
      context.create(namespace: "notes", key: "pinned", value: nil, idempotency_key: "")
    end
    assert_empty @transport.requests
  end

  def test_fetch_reads_the_full_projection_with_its_value
    entry = entries([[200, {}, { "store_entry" => FULL }]]).fetch(SUMMARY.fetch("public_id"))

    assert_equal :get, request.fetch(:method)
    assert_equal "#{ENTRIES_PATH}/#{SUMMARY.fetch("public_id")}", request.fetch(:path)
    assert_equal ["sk-cybros-session-v1-stored.secret"], entry.value.fetch("list")
  end

  # Hostile ids travel percent-encoded as single path segments: URI
  # metacharacters cannot re-address another route, and a space never leaks
  # the transport's raw URI error.
  def test_fetch_percent_encodes_a_hostile_entry_public_id_into_one_path_segment
    { "a b" => "a%20b", "a/../b" => "a%2F..%2Fb" }.each do |hostile, encoded|
      entries([[200, {}, { "store_entry" => FULL }]]).fetch(hostile)

      assert_equal "#{ENTRIES_PATH}/#{encoded}", request.fetch(:path)
    end
  end

  def test_a_hostile_workspace_id_stays_one_segment_of_the_nested_path
    @transport = CybrosAgentTest::FakeTransport.new(
      [[200, {}, { "store_entries" => [], "pagination" => { "next_after" => nil } }]]
    )
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
      .workspace("a b/c")
      .store_entries
      .list

    assert_equal "/agent_api/v1/workspaces/a%20b%2Fc/store_entries", request.fetch(:path)
  end

  # The context binds a PATH, not a workspace: one class serves the
  # workspace, conversation and profile doors, and the route it was handed
  # is the one thing that says whose store it is.
  def test_the_nested_context_keeps_an_immutable_path_binding
    source_public_id = +"019f0000-0000-7000-8000-000000000101"
    @transport = CybrosAgentTest::FakeTransport.new(
      [[200, {}, { "store_entries" => [], "pagination" => { "next_after" => nil } }]]
    )
    context = CybrosAgent::Client.new(
      base_url: "http://example.test", credential: "sk-member", transport: @transport
    ).workspace(source_public_id).store_entries

    source_public_id.replace("019f0000-0000-7000-8000-000000000999")
    context.list

    assert_predicate context.path, :frozen?
    assert_equal ENTRIES_PATH, context.path
    assert_equal ENTRIES_PATH, request.fetch(:path)
    refute_respond_to context, :workspace_public_id,
      "the door is the path; a workspace id would be one host's name on a three-host context"
  end

  # The Full projection must actually carry value: an answer without the
  # member is a wrong shape, not an entry that happens to hold nothing.
  def test_a_full_projection_missing_its_value_member_is_malformed
    context = entries([[200, {}, { "store_entry" => SUMMARY }]])

    assert_raises(CybrosAgent::Api::MalformedResponse) { context.fetch(SUMMARY.fetch("public_id")) }
  end

  def test_update_patches_the_value_under_the_required_lock_version
    entries([[200, {}, { "store_entry" => FULL }]])
      .update(SUMMARY.fetch("public_id"), value: nil, lock_version: 2)

    assert_equal :patch, request.fetch(:method)
    assert_equal "#{ENTRIES_PATH}/#{SUMMARY.fetch("public_id")}", request.fetch(:path)
    body = request.fetch(:body).fetch("store_entry")
    assert body.key?("value")
    assert_nil body.fetch("value")
    assert_equal 2, body.fetch("lock_version")
  end

  def test_delete_sends_lock_version_as_a_query_parameter_and_returns_nil
    contract = CybrosAgentTest::ContractFixtures.pack("store_entries.json")
    response_fixture = contract.fetch("valid_delete_fixture")
    delete_params = contract.fetch("valid_delete_params")
    result = entries([[
      response_fixture.fetch("status"),
      response_fixture.fetch("headers", {}),
      response_fixture.fetch("body"),
    ]]).delete(
      SUMMARY.fetch("public_id"),
      lock_version: delete_params.fetch("lock_version")
    )

    assert_nil result
    assert_equal :delete, request.fetch(:method)
    assert_equal "#{ENTRIES_PATH}/#{SUMMARY.fetch("public_id")}", request.fetch(:path)
    assert_equal delete_params, request.fetch(:params)
    assert_nil request.fetch(:body)
  end

  # A 2xx outside the endpoint's one success status is a broken contract, not
  # a different flavor of success and not a server failure.
  def test_an_unexpected_success_status_is_typed_malformed
    context = entries([[200, {}, nil]])

    assert_raises(CybrosAgent::Api::MalformedResponse) do
      context.delete(SUMMARY.fetch("public_id"), lock_version: 2)
    end
  end

  def test_a_blank_entry_public_id_is_refused_before_transport
    context = entries([])

    assert_raises(ArgumentError) { context.fetch("") }
    assert_raises(ArgumentError) { context.update("", value: nil, lock_version: 1) }
    assert_raises(ArgumentError) { context.delete("", lock_version: 1) }
    assert_empty @transport.requests
  end

  def test_the_conflict_family_carries_each_envelope_code
    %w[key_taken entry_limit_reached workspace_not_active stale_object].each do |code|
      error = assert_raises(CybrosAgent::Api::Conflict) do
        entries([[409, {}, { "error" => { "code" => code, "message" => "refused" } }]])
          .create(namespace: "notes", key: "pinned", value: nil, idempotency_key: "key-1")
      end

      assert_equal code, error.code
    end

    error = assert_raises(CybrosAgent::Api::Forbidden) do
      entries([[403, {}, { "error" => { "code" => "workspace_agent_identifier_mismatch" } }]])
        .update(SUMMARY.fetch("public_id"), value: nil, lock_version: 2)
    end
    assert_equal "workspace_agent_identifier_mismatch", error.code

    error = assert_raises(CybrosAgent::Api::ContentTooLarge) do
      entries([[413, {}, { "error" => { "code" => "content_too_large" } }]])
        .update(SUMMARY.fetch("public_id"), value: "x", lock_version: 2)
    end
    assert_equal "content_too_large", error.code
  end

  def test_the_value_is_deep_frozen_and_redacted_from_every_diagnostic
    entry = entries([[200, {}, { "store_entry" => FULL }]]).fetch(SUMMARY.fetch("public_id"))

    assert_predicate entry.value, :frozen?
    assert_predicate entry.value.fetch("list"), :frozen?
    assert_predicate entry.value.fetch("token"), :frozen?

    [entry.inspect, entry.to_s, PP.pp(entry, +"")].each do |diagnostic|
      refute_includes diagnostic, "stored.secret"
      assert_includes diagnostic, "value=[REDACTED]"
      assert_includes diagnostic, entry.public_id
    end
  end
end
