require "test_helper"
require "pp"
require_relative "../support/contract_fixtures"

# The member plane's Workspace surface: the collection resource, the scoping context,
# the omission-versus-null request grammar, and the typed Basic/Full projections whose
# application-owned JSON never reaches a diagnostic.
class ApiWorkspacesTest < Minitest::Test
  SUMMARY = {
    "public_id" => "019f0000-0000-7000-8000-000000000101",
    "name" => "Notes",
    "access_mode" => "private",
    "state" => "active",
    "dedicated" => true,
    "lock_version" => 3,
    "archived_at" => nil,
    "created_at" => "2026-07-30T00:00:00Z",
    "updated_at" => "2026-07-30T01:00:00Z",
  }.freeze

  FULL = SUMMARY.merge(
    "metadata" => {
      "purpose" => "notes",
      "token" => "sk-cybros-api-v1-metadata.secret",
      "nested" => { "refresh" => "rt-metadata.secret" },
    },
    "owner" => {
      "public_id" => "019f0000-0000-7000-8000-000000000201",
      "display_name" => "Steward",
    },
    "creator" => {
      "public_id" => "019f0000-0000-7000-8000-000000000301",
      "display_name" => "Notes assistant",
      "kind" => "agent",
    },
    "tool_provider_overrides" => {}
  ).freeze

  WORKSPACE_PATH = "/agent_api/v1/workspaces".freeze
  PROVIDER_ID = "019f0000-0000-7000-8000-000000000501".freeze
  OVERRIDES = {
    "nexus.memory" => {
      "provider_public_id" => PROVIDER_ID,
      "display_name" => "Memory provider",
      "assignment_scope" => "account_wide",
    },
  }.freeze

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
  end

  def request
    assert_equal 1, @transport.requests.length
    @transport.requests.fetch(0)
  end

  def test_list_reads_the_collection_with_its_filters_as_query_parameters
    page = client([[200, {}, {
      "workspaces" => [SUMMARY],
      "pagination" => { "next_after" => "cursor-1" },
    }]]).workspaces.list(state: "archived", dedicated_to_current_agent: true, after: "cursor-0", limit: 50)

    assert_equal :get, request.fetch(:method)
    assert_equal WORKSPACE_PATH, request.fetch(:path)
    assert_nil request.fetch(:body)
    assert_equal(
      {
        "state" => "archived", "dedicated_to_current_agent" => true,
        "after" => "cursor-0", "limit" => 50,
      },
      request.fetch(:params)
    )

    assert_instance_of CybrosAgent::Api::Page, page
    assert_equal "cursor-1", page.next_after
    summary = page.items.fetch(0)
    assert_instance_of CybrosAgent::Api::WorkspaceSummary, summary
    assert_equal "019f0000-0000-7000-8000-000000000101", summary.public_id
    assert_equal "private", summary.access_mode
    assert_equal true, summary.dedicated
    assert_equal 3, summary.lock_version
    assert_nil summary.archived_at
    refute_respond_to summary, :metadata,
      "the Basic projection never carries application JSON (2026-07-30 plan)"
  end

  def test_list_without_filters_sends_no_query_parameters
    page = client([[200, {}, { "workspaces" => [], "pagination" => { "next_after" => nil } }]])
      .workspaces.list

    assert_nil request.fetch(:params)
    assert_empty page.items
    assert_nil page.next_after
  end

  def test_list_rejects_pagination_missing_its_required_next_after_member
    workspaces = client([[200, {}, { "workspaces" => [], "pagination" => {} }]]).workspaces

    assert_raises(CybrosAgent::Api::MalformedResponse) { workspaces.list }
  end

  def test_create_posts_the_envelope_under_its_client_minted_idempotency_key
    workspace = client([[201, {}, { "workspace" => FULL }]]).workspaces.create(
      name: "Notes", idempotency_key: "key-1", metadata: { "purpose" => "notes" }
    ).workspace

    assert_equal :post, request.fetch(:method)
    assert_equal WORKSPACE_PATH, request.fetch(:path)
    assert_equal "key-1", request.fetch(:headers).fetch("Idempotency-Key")
    assert_equal(
      { "workspace" => {
        "name" => "Notes", "metadata" => { "purpose" => "notes" },
      } },
      request.fetch(:body)
    )

    assert_instance_of CybrosAgent::Api::Workspace, workspace
    assert_equal "Notes", workspace.name
    assert_instance_of CybrosAgent::Api::WorkspaceOwnerSummary, workspace.owner
    assert_equal "Steward", workspace.owner.display_name
    assert_instance_of CybrosAgent::Api::WorkspaceCreatorSummary, workspace.creator
    assert_equal "agent", workspace.creator.kind
  end

  def test_create_does_not_expose_a_dedication_selector
    # RBS RUNTIME INSTRUMENTATION GETS IN FRONT OF THIS ONE. The claim is
    # that Ruby itself refuses the keyword; under the type hook the call is
    # rejected as a TypeError first, so the assertion cannot see what it is
    # about. The behavior suite runs it for real — this skip costs three
    # assertions on the conformance pass and buys the whole namespace back.
    skip("the RBS hook answers before Ruby's own ArgumentError") if ENV["RBS_TEST_TARGET"]

    workspaces = client([]).workspaces

    assert_raises(ArgumentError) do
      workspaces.create(name: "Notes", idempotency_key: "key-1", dedicated: true)
    end
  end

  # The UNSET grammar: an omitted keyword sends no field at all,
  # while an explicit nil travels as JSON null for the server to judge.
  def test_create_distinguishes_omitted_keywords_from_explicit_null
    client([[201, {}, { "workspace" => FULL }]]).workspaces.create(
      name: "Notes", idempotency_key: "key-1", metadata: nil
    )

    assert_equal({ "workspace" => { "name" => "Notes", "metadata" => nil } }, request.fetch(:body))
  end

  def test_create_with_only_its_required_keywords_sends_only_the_name
    client([[201, {}, { "workspace" => FULL }]]).workspaces.create(name: "Notes", idempotency_key: "key-1")

    assert_equal({ "workspace" => { "name" => "Notes" } }, request.fetch(:body))
  end

  # The SDK never silently mints a key: a blank one is refused
  # before any transport call rather than left to the server's 400.
  def test_create_refuses_a_blank_idempotency_key_before_transport
    workspaces = client([]).workspaces

    assert_raises(ArgumentError) { workspaces.create(name: "Notes", idempotency_key: "") }
    assert_empty @transport.requests
  end

  def test_fetch_reads_one_workspace_by_public_id
    workspace = client([[200, {}, { "workspace" => FULL }]])
      .workspaces.fetch("019f0000-0000-7000-8000-000000000101")

    assert_equal :get, request.fetch(:method)
    assert_equal "#{WORKSPACE_PATH}/019f0000-0000-7000-8000-000000000101", request.fetch(:path)
    assert_equal "sk-member", request.fetch(:credential)
    assert_equal({ "purpose" => "notes" }, workspace.metadata.slice("purpose"))
  end

  # Hostile ids travel percent-encoded as single path segments: URI
  # metacharacters cannot re-address another route, and a space never leaks
  # the transport's raw URI error.
  def test_fetch_percent_encodes_a_hostile_public_id_into_one_path_segment
    { "a b" => "a%20b", "a/../b" => "a%2F..%2Fb" }.each do |hostile, encoded|
      client([[200, {}, { "workspace" => FULL }]]).workspaces.fetch(hostile)

      assert_equal "#{WORKSPACE_PATH}/#{encoded}", request.fetch(:path)
    end
  end

  def test_context_commands_percent_encode_a_hostile_public_id_into_one_path_segment
    { "a b" => "a%20b", "a/../b" => "a%2F..%2Fb" }.each do |hostile, encoded|
      client([[200, {}, { "workspace" => FULL }]]).workspace(hostile).archive(lock_version: 3)

      assert_equal "#{WORKSPACE_PATH}/#{encoded}/archival", request.fetch(:path)
    end
  end

  def test_the_context_is_pure_scoping_and_refuses_a_blank_public_id
    workspace = client([]).workspace("019f0000-0000-7000-8000-000000000101")

    assert_equal "019f0000-0000-7000-8000-000000000101", workspace.public_id
    assert_predicate workspace.public_id, :frozen?
    assert_empty @transport.requests, "constructing a context performs no HTTP"
    assert_raises(ArgumentError) { client([]).workspace("") }
  end

  def test_the_context_snapshots_its_public_id_before_binding_requests
    source_public_id = +"019f0000-0000-7000-8000-000000000101"
    workspace = client([[200, {}, { "workspace" => FULL }]]).workspace(source_public_id)

    source_public_id.replace("019f0000-0000-7000-8000-000000000999")
    workspace.archive(lock_version: 3)

    assert_equal "019f0000-0000-7000-8000-000000000101", workspace.public_id
    assert_equal "#{WORKSPACE_PATH}/019f0000-0000-7000-8000-000000000101/archival", request.fetch(:path)
  end

  def test_update_patches_name_and_metadata_under_the_required_lock_version
    workspace = client([[200, {}, { "workspace" => FULL }]])
      .workspace(SUMMARY.fetch("public_id"))
      .update(name: "Renamed", lock_version: 3)

    assert_equal :patch, request.fetch(:method)
    assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}", request.fetch(:path)
    assert_equal({ "workspace" => { "name" => "Renamed", "lock_version" => 3 } }, request.fetch(:body))
    assert_instance_of CybrosAgent::Api::Workspace, workspace
  end

  def test_update_sends_an_explicit_nil_metadata_as_null
    client([[200, {}, { "workspace" => FULL }]])
      .workspace(SUMMARY.fetch("public_id"))
      .update(metadata: nil, lock_version: 3)

    assert_equal({ "workspace" => { "metadata" => nil, "lock_version" => 3 } }, request.fetch(:body))
  end

  # The at-least-one contract validates before transport: a
  # lock_version-only patch is the caller's bug, not a server 422.
  def test_update_requires_name_or_metadata_before_transport
    workspace = client([]).workspace(SUMMARY.fetch("public_id"))

    assert_raises(ArgumentError) { workspace.update(lock_version: 3) }
    assert_empty @transport.requests
  end

  def test_update_access_mode_puts_the_singular_command_resource
    client([[200, {}, { "workspace" => FULL }]])
      .workspace(SUMMARY.fetch("public_id"))
      .update_access_mode(access_mode: "account_wide", lock_version: 3)

    assert_equal :put, request.fetch(:method)
    assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}/access_mode", request.fetch(:path)
    assert_equal(
      { "access_mode" => { "access_mode" => "account_wide", "lock_version" => 3 } },
      request.fetch(:body)
    )
  end

  # THE PROVIDER OVERRIDE OPT-IN: a whole replacement of the
  # workspace's override map under the required lock_version, PUT on its
  # own singular resource — the access-mode command's shape.
  def test_set_tool_provider_overrides_puts_the_whole_map_under_the_required_lock_version
    workspace = client([[200, {}, { "workspace" => FULL.merge("tool_provider_overrides" => OVERRIDES) }]])
      .workspace(SUMMARY.fetch("public_id"))
      .set_tool_provider_overrides(overrides: { "nexus.memory" => PROVIDER_ID }, lock_version: 3)

    assert_equal :put, request.fetch(:method)
    assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}/tool_provider_overrides", request.fetch(:path)
    assert_equal(
      { "tool_provider_overrides" => { "overrides" => { "nexus.memory" => PROVIDER_ID }, "lock_version" => 3 } },
      request.fetch(:body)
    )
    assert_equal PROVIDER_ID, workspace.tool_provider_overrides.fetch("nexus.memory").provider_public_id
  end

  # `{}` is the clearing PUT — an explicit empty map, never an absent key:
  # the server reads absence as a missing parameter, not as "clear".
  def test_set_tool_provider_overrides_with_an_empty_map_clears
    workspace = client([[200, {}, { "workspace" => FULL }]])
      .workspace(SUMMARY.fetch("public_id"))
      .set_tool_provider_overrides(overrides: {}, lock_version: 4)

    assert_equal(
      { "tool_provider_overrides" => { "overrides" => {}, "lock_version" => 4 } },
      request.fetch(:body)
    )
    assert_equal({}, workspace.tool_provider_overrides)
  end

  def test_set_tool_provider_overrides_refuses_a_non_hash_before_transport
    # The RBS hook refuses a non-Hash as a TypeError before the guard runs
    # (the dedication-selector case above); the behavior suite runs it for real.
    skip("the RBS hook answers before Ruby's own ArgumentError") if ENV["RBS_TEST_TARGET"]

    workspace = client([]).workspace(SUMMARY.fetch("public_id"))

    [nil, "nexus.memory", [["nexus.memory", PROVIDER_ID]]].each do |overrides|
      assert_raises(ArgumentError) { workspace.set_tool_provider_overrides(overrides: overrides, lock_version: 3) }
    end
    assert_empty @transport.requests
  end

  # The read renders the override with the provider's name and scope; a
  # reaped provider renders nils beside its id (the snapshot outlives it).
  def test_the_full_projection_types_the_override_map
    reaped = { "provider_public_id" => "019f0000-0000-7000-8000-000000000502",
               "display_name" => nil, "assignment_scope" => nil }
    typed = client([[200, {}, {
      "workspace" => FULL.merge("tool_provider_overrides" => OVERRIDES.merge("nexus.other" => reaped)),
    }]]).workspaces.fetch(SUMMARY.fetch("public_id"))

    memory = typed.tool_provider_overrides.fetch("nexus.memory")
    assert_instance_of CybrosAgent::Api::ToolProviderOverride, memory
    assert_equal PROVIDER_ID, memory.provider_public_id
    assert_equal "Memory provider", memory.display_name
    assert_equal "account_wide", memory.assignment_scope
    other = typed.tool_provider_overrides.fetch("nexus.other")
    assert_equal reaped.fetch("provider_public_id"), other.provider_public_id
    assert_nil other.display_name
    assert_nil other.assignment_scope
    assert_equal %w[nexus.memory nexus.other], typed.tool_provider_overrides.keys
  end

  # Frozen like metadata — a value object can never disagree with what the
  # server said — but not hidden: the map names a provider, never a secret.
  def test_the_override_map_is_frozen_and_visible_in_diagnostics
    workspace = client([[200, {}, { "workspace" => FULL.merge("tool_provider_overrides" => OVERRIDES) }]])
      .workspaces.fetch(SUMMARY.fetch("public_id"))

    assert_predicate workspace.tool_provider_overrides, :frozen?
    assert_predicate workspace.tool_provider_overrides.keys.fetch(0), :frozen?
    assert_predicate workspace.tool_provider_overrides.fetch("nexus.memory"), :frozen?
    assert_raises(FrozenError) { workspace.tool_provider_overrides["nexus.graph"] = nil }

    [workspace.inspect, workspace.to_s, PP.pp(workspace, +"")].each do |diagnostic|
      assert_includes diagnostic, "nexus.memory"
      assert_includes diagnostic, PROVIDER_ID
      assert_includes diagnostic, "metadata=[REDACTED]"
    end
  end

  def test_the_override_refusals_carry_their_envelope_codes
    %w[reserved_namespace provider_not_eligible provider_incomplete].each do |code|
      error = assert_raises(CybrosAgent::Api::InvalidRequest) do
        client([[422, {}, { "error" => { "code" => code, "message" => "refused" } }]])
          .workspace(SUMMARY.fetch("public_id"))
          .set_tool_provider_overrides(overrides: { "nexus.memory" => PROVIDER_ID }, lock_version: 3)
      end

      assert_equal code, error.code
    end
  end

  def test_transfer_ownership_posts_the_target_and_lock_version
    client([[200, {}, { "workspace" => FULL }]])
      .workspace(SUMMARY.fetch("public_id"))
      .transfer_ownership(target_user_public_id: "019f0000-0000-7000-8000-000000000401", lock_version: 3)

    assert_equal :post, request.fetch(:method)
    assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}/ownership_transfer", request.fetch(:path)
    assert_equal(
      { "ownership_transfer" => {
        "target_user_public_id" => "019f0000-0000-7000-8000-000000000401", "lock_version" => 3,
      } },
      request.fetch(:body)
    )
  end

  def test_archive_and_restore_post_their_lifecycle_commands
    { archive: "archival", restore: "restoration" }.each do |command, action|
      client([[200, {}, { "workspace" => FULL }]])
        .workspace(SUMMARY.fetch("public_id"))
        .public_send(command, lock_version: 3)

      assert_equal :post, request.fetch(:method)
      assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}/#{action}", request.fetch(:path)
      assert_equal({ "command" => { "lock_version" => 3 } }, request.fetch(:body))
    end
  end

  # Deletion is an accepted lifecycle command: lock_version travels as a query
  # parameter and the answer is the Full projection, not an empty body.
  def test_delete_sends_lock_version_as_a_query_parameter_and_returns_the_workspace
    workspace = client([[200, {}, { "workspace" => FULL.merge("state" => "deleting") }]])
      .workspace(SUMMARY.fetch("public_id"))
      .delete(lock_version: 3)

    assert_equal :delete, request.fetch(:method)
    assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}", request.fetch(:path)
    assert_nil request.fetch(:body)
    assert_equal({ "lock_version" => 3 }, request.fetch(:params))
    assert_equal "deleting", workspace.state
  end

  def test_store_entries_returns_a_context_bound_to_this_workspace
    entries = client([]).workspace(SUMMARY.fetch("public_id")).store_entries

    assert_instance_of CybrosAgent::Api::StoreEntriesContext, entries
    assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}/store_entries", entries.path,
      "the workspace handle hands the context its own door; the route is the binding"
  end

  # --- the room's character --------------------------------------
  #
  # `workspace.prompt_documents` is the workspace's slot door: the
  # `character` slot the default template places behind the agent's
  # `system_prompt` and ahead of the person's `persona`. The SLOT is the
  # path's member segment — one word, never a slash — so PUT is the whole
  # replacement by URL, and the other slots are refused here by name.

  PROMPT_PATH = "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}/prompt_documents".freeze

  def prompt_pack = CybrosAgentTest::ContractFixtures.pack("prompt_documents.json")

  def test_the_characters_door_is_bound_to_this_workspace
    documents = client([]).workspace(SUMMARY.fetch("public_id")).prompt_documents

    assert_instance_of CybrosAgent::Api::PromptDocumentsContext, documents
    assert_equal PROMPT_PATH, documents.path
  end

  def test_listing_the_slots_reads_sizes_versions_and_ages_never_text
    docs = client([[200, {}, prompt_pack.fetch("valid_list_fixture")]])
      .workspace(SUMMARY.fetch("public_id")).prompt_documents.list

    assert_equal :get, request.fetch(:method)
    assert_equal PROMPT_PATH, request.fetch(:path)
    assert_equal 1, docs.length
    assert_instance_of CybrosAgent::Api::PromptDocument, docs.first
    assert_equal %w[character system], [docs.first.slot, docs.first.role]
    assert_equal 2, docs.first.version
    assert_nil docs.first.content, "a listing carries no text"
    refute docs.first.to_h.key?(:content), "absent stays absent"
  end

  def test_reading_one_slot_gets_its_member_path_and_the_content_as_written
    doc = client([[200, {}, prompt_pack.fetch("valid_fixture")]])
      .workspace(SUMMARY.fetch("public_id")).prompt_documents.read("character")

    assert_equal :get, request.fetch(:method)
    assert_equal "#{PROMPT_PATH}/character", request.fetch(:path)
    assert_equal prompt_pack.dig("valid_fixture", "prompt_document", "content"), doc.content,
      "the macros ride unrendered; the assembler substitutes them at compile"
    assert_equal 39, doc.bytesize
  end

  def test_writing_a_slot_puts_the_whole_document_by_its_url
    doc = client([[200, {}, prompt_pack.fetch("valid_fixture")]])
      .workspace(SUMMARY.fetch("public_id")).prompt_documents
      .write("character", "You are in {{workspace}} with {{user}}.")

    assert_equal :put, request.fetch(:method)
    assert_equal "#{PROMPT_PATH}/character", request.fetch(:path)
    assert_equal({ "prompt_document" => { "content" => "You are in {{workspace}} with {{user}}." } },
      request.fetch(:body), "no role sent: the kernel's default is `system`")
    refute request.fetch(:headers).key?("Idempotency-Key"), "a whole replacement converges on retry"
    assert_equal "character", doc.slot
    assert_equal 2, doc.version, "a rewrite bumps the version; the door answers 200 either time"
  end

  def test_writing_a_slot_with_a_role_sends_the_role
    client([[200, {}, prompt_pack.fetch("valid_fixture")]])
      .workspace(SUMMARY.fetch("public_id")).prompt_documents
      .write("character", "Narrate.", role: "developer")

    assert_equal({ "prompt_document" => { "content" => "Narrate.", "role" => "developer" } },
      request.fetch(:body))
  end

  def test_deleting_a_slot_answers_nothing
    assert_nil client([[204, {}, nil]]).workspace(SUMMARY.fetch("public_id")).prompt_documents.delete("character")

    assert_equal :delete, request.fetch(:method)
    assert_equal "#{PROMPT_PATH}/character", request.fetch(:path)
  end

  def test_the_slot_fence_and_the_stranger_macro_are_the_kernels_typed_refusals
    unavailable = prompt_pack.fetch("valid_error_fixture")
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      client([[unavailable.fetch("status"), {}, unavailable.fetch("body")]])
        .workspace(SUMMARY.fetch("public_id")).prompt_documents.write("persona", "x")
    end
    assert_equal "prompt_slot_unavailable", error.code, "a persona belongs on a person, not a room"

    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      client([[422, {}, { "error" => { "code" => "prompt_document_macro_unknown", "message" => "{{history}}" } }]])
        .workspace(SUMMARY.fetch("public_id")).prompt_documents.write("character", "{{history}}")
    end
    assert_equal "prompt_document_macro_unknown", error.code

    error = assert_raises(CybrosAgent::Api::NotFound) do
      client([[404, {}, { "error" => { "code" => "prompt_document_not_found", "message" => "none" } }]])
        .workspace(SUMMARY.fetch("public_id")).prompt_documents.read("character")
    end
    assert_equal "prompt_document_not_found", error.code
  end

  def test_the_new_status_ladder_rungs_carry_their_envelope_codes
    {
      [403, "not_workspace_owner"] => CybrosAgent::Api::Forbidden,
      [409, "stale_object"] => CybrosAgent::Api::Conflict,
      [413, "content_too_large"] => CybrosAgent::Api::ContentTooLarge,
    }.each do |(status, code), error_class|
      error = assert_raises(error_class) do
        client([[status, {}, { "error" => { "code" => code, "message" => "refused" } }]])
          .workspace(SUMMARY.fetch("public_id"))
          .update(name: "Renamed", lock_version: 0)
      end

      assert_equal code, error.code
    end
  end

  def test_a_success_with_the_wrong_shape_is_typed_malformed
    [
      { "workspace" => nil },
      { "workspace" => SUMMARY },
      { "workspace" => FULL.merge("dedicated" => "yes") },
      { "workspaces" => "nope", "pagination" => { "next_after" => nil } },
      { "workspaces" => [], "pagination" => nil },
      { "workspaces" => ["not-an-object"], "pagination" => { "next_after" => nil } },
    ].each do |body|
      workspaces = client([[200, {}, body]]).workspaces
      assert_raises(CybrosAgent::Api::MalformedResponse) do
        body.key?("workspace") ? workspaces.fetch(SUMMARY.fetch("public_id")) : workspaces.list
      end
    end
  end

  def test_metadata_is_deep_frozen_and_redacted_from_every_diagnostic
    workspace = client([[200, {}, { "workspace" => FULL }]])
      .workspaces.fetch(SUMMARY.fetch("public_id"))

    assert_predicate workspace.metadata, :frozen?
    assert_predicate workspace.metadata.fetch("nested"), :frozen?
    assert_predicate workspace.metadata.fetch("token"), :frozen?
    assert_equal "sk-cybros-api-v1-metadata.secret", workspace.metadata.fetch("token")

    [workspace.inspect, workspace.to_s, PP.pp(workspace, +"")].each do |diagnostic|
      refute_includes diagnostic, "metadata.secret"
      refute_includes diagnostic, "purpose"
      assert_includes diagnostic, "metadata=[REDACTED]"
      assert_includes diagnostic, workspace.public_id
    end
  end

  # THE PRINCIPALS LISTING: the members with access to this
  # workspace, of either kind, read strictly against the pack's fixture —
  # every key present on every row, a Human's agent fields null. The one
  # place an agent reads its peers' ids and its own steward's.
  def test_principals_lists_the_members_with_access_from_the_pack_fixture
    pack = CybrosAgentTest::ContractFixtures.pack("workspaces.json")
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, pack.fetch("valid_principals_fixture")]])
    principals = CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: transport)
      .workspace(SUMMARY.fetch("public_id")).principals

    request = transport.requests.fetch(0)
    assert_equal :get, request.fetch(:method)
    assert_equal "#{WORKSPACE_PATH}/#{SUMMARY.fetch("public_id")}/principals", request.fetch(:path)
    assert_equal pack.fetch("principal_projection").sort,
      %w[public_id handle kind display_name agent_identifier steward_public_id].sort
    assert_predicate principals, :frozen?
    steward, agent = principals
    assert_instance_of CybrosAgent::Api::Principal, steward
    assert_predicate steward, :human?
    assert_nil steward.agent_identifier
    assert_nil steward.steward_public_id
    assert_predicate agent, :agent?
    assert_equal "lark", agent.handle, "the handle a peer may address"
    assert_equal "fixture-owner", steward.handle
    assert_equal "fixture-agent", agent.agent_identifier
    assert_equal steward.public_id, agent.steward_public_id
    assert_includes agent.inspect, agent.public_id

    malformed = { "principals" => [pack.dig("valid_principals_fixture", "principals", 0).except("kind")] }
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, malformed]])
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: transport)
        .workspace(SUMMARY.fetch("public_id")).principals
    end
  end

  # THE ROOM'S OWN MEMORY DOOR: `workspace.memory`
  # is the `workspace/` scope without a conversation — the same four verbs,
  # the same path-in-body rule, at the workspace's own path; the pack's
  # `door_scopes` says this door serves `workspace/` alone, and a path of
  # another scope is the kernel's `memory_scope_unavailable`.
  def test_the_workspaces_memory_door_serves_the_workspace_scope_at_its_own_path
    pack = CybrosAgentTest::ContractFixtures.pack("memory_documents.json")
    assert_equal %w[workspace], pack.fetch("door_scopes").fetch("workspace")
    fixture = pack.fetch("valid_fixture").fetch("memory")
    write = pack.fetch("valid_write_request").fetch("memory")

    doc = client([[201, {}, { "memory" => fixture }]]).workspace(SUMMARY.fetch("public_id")).memory
      .write(write.fetch("path"), write.fetch("content"),
        expected_public_id: write.fetch("expected_public_id"), expected_lock_version: write.fetch("expected_lock_version"))
    assert_equal "/agent_api/v1/workspaces/#{SUMMARY.fetch("public_id")}/memory", request.fetch(:path)
    assert_equal :post, request.fetch(:method)
    assert_equal({ "memory" => write }, request.fetch(:body))
    assert_equal "workspace", doc.scope
    assert_equal fixture.fetch("content"), doc.content

    listed = client([[200, {}, pack.fetch("valid_list_fixture")]]).workspace(SUMMARY.fetch("public_id")).memory.list
    assert_equal "/agent_api/v1/workspaces/#{SUMMARY.fetch("public_id")}/memory", request.fetch(:path)
    assert_equal :get, request.fetch(:method)
    assert_nil listed.first.content, "a listing carries sizes and ages, never text"

    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      client([[422, {}, { "error" => { "code" => "memory_scope_unavailable", "message" => "not this door's" } }]])
        .workspace(SUMMARY.fetch("public_id")).memory.read("user/notes.md")
    end
    assert_equal "memory_scope_unavailable", error.code
    assert_equal({ "memory" => { "path" => "user/notes.md" } }, request.fetch(:body), "the path rides the body on a read")
  end
end
