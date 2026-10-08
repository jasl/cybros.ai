require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  # --- the collection -------------------------------------------------

  def test_the_working_list_and_the_recycle_bin_are_separate_resources
    page = conversations([[200, {}, contract.fetch("valid_list_fixture")]]).list

    assert_equal BASE, request.fetch(:path)
    assert_equal CONVERSATION_ID, page.items.first.public_id
    refute_predicate page.items.first, :archived?
    assert_predicate page.items.first, :busy?, "an active turn IS the busy signal"

    conversations([[200, {}, contract.fetch("valid_list_fixture")]]).archived
    assert_equal "#{BASE}/archived", request.fetch(:path),
      "the bin is its own resource, not a filter flag"
  end

  # SIDE CONVERSATIONS are hidden from the working list; `side: true`
  # is the one flag that lists them — the wire's `?side=1`.
  def test_the_working_list_hides_sides_and_side_true_lists_them
    page = conversations([[200, {}, contract.fetch("valid_list_fixture")]]).list
    assert_nil request.fetch(:params), "the default sends no flag"
    refute_predicate page.items.first, :side?

    conversations([[200, {}, contract.fetch("valid_list_fixture")]]).list(side: true, limit: 5)
    assert_equal({ "limit" => 5, "side" => "1" }, request.fetch(:params))
  end

  def test_conversation_lists_forward_activity_order_and_cursor_together
    options = { order_by: "last_activity_at", order: "desc", after: "opaque", limit: 2 }
    wire = options.transform_keys(&:to_s)
    conversations([[200, {}, contract.fetch("valid_list_fixture")]]).list(**options, side: true)
    assert_equal wire.merge("side" => "1"), request.fetch(:params)

    conversations([[200, {}, contract.fetch("valid_list_fixture")]]).archived(**options)
    assert_equal wire, request.fetch(:params)

    chat([[200, {}, contract.fetch("valid_list_fixture")]]).children(**options)
    assert_equal wire, request.fetch(:params)
  end

  def test_direct_fork_source_is_nullable_on_both_shapes_and_independent_of_parent
    root = chat([[200, {}, contract.fetch("valid_fixture")]]).fetch
    assert_nil root.source_conversation_public_id

    forked = contract.fetch("forked_conversation_fixture")
    list = { "conversations" => [forked], "pagination" => { "next_after" => nil } }
    summary = conversations([[200, {}, list]]).list(side: true).items.first
    assert_equal CONVERSATION_ID, summary.source_conversation_public_id
    assert_nil summary.parent
    assert_nil summary.forked_from_turn_public_id, "an empty Side still has its direct source"

    full = contract.fetch("valid_fixture").fetch("conversation").merge(forked)
    conversation = chat([[200, {}, { "conversation" => full }]]).fetch
    assert_equal CONVERSATION_ID, conversation.source_conversation_public_id

    full["source_conversation_public_id"] = nil
    hidden_source = chat([[200, {}, { "conversation" => full }]]).fetch
    assert_nil hidden_source.source_conversation_public_id
  end

  # THE PARENT FACTS: a spawned child carries `parent` as one
  # block — the parent's id, the `spawn` call's key (the id the spawning
  # model read back; nil once the spawning run is reaped), the label —
  # read STRICTLY when present (the pack pins the child's shape); a
  # top-level row says nil, and `subagent?` reads the block's presence.
  def test_a_spawned_child_reads_its_parent_block_and_a_top_level_row_reads_nil
    top = conversations([[200, {}, contract.fetch("valid_list_fixture")]]).list.items.first
    assert_nil top.parent
    refute_predicate top, :subagent?
    refute top.to_h.key?(:parent_conversation_public_id), "one block, never a second flat spelling"

    child_row = contract.fetch("spawned_child_fixture")
    page = chat([[200, {}, { "conversations" => [child_row], "pagination" => { "next_after" => nil } }]]).children
    assert_equal "#{PATH}/children", request.fetch(:path)
    child = page.items.first
    assert_predicate child, :subagent?
    assert_equal CONVERSATION_ID, child.parent.public_id
    assert_equal child_row.dig("parent", "spawn_node_key"), child.parent.spawn_node_key
    assert_equal child_row.dig("parent", "label"), child.parent.label
    assert_kind_of CybrosAgent::Api::ConversationParent, child.parent

    reaped = child_row.merge("parent" => child_row.fetch("parent").merge("spawn_node_key" => nil, "label" => nil))
    row = chat([[200, {}, { "conversations" => [reaped], "pagination" => { "next_after" => nil } }]]).children.items.first
    assert_nil row.parent.spawn_node_key, "a reaped call leaves the parent named"
    assert_nil row.parent.label
    assert_predicate row, :subagent?
  end

  def test_create_sends_the_callers_own_key_and_reports_a_replay
    created = conversations([[201, { "Idempotency-Replayed" => "false" }, contract.fetch("valid_fixture")]])
      .create(idempotency_key: "key-1", title: "Planning", metadata: { "topic" => "planning" })

    assert_equal :post, request.fetch(:method)
    assert_equal "key-1", request.fetch(:headers).fetch("Idempotency-Key")
    fields = request.fetch(:body).fetch("conversation")
    assert_equal "Planning", fields.fetch("title")
    refute_predicate created, :replayed?
    assert_equal CONVERSATION_ID, created.public_id

    replayed = conversations([[201, { "idempotency-replayed" => "true" }, contract.fetch("valid_fixture")]])
      .create(idempotency_key: "key-1")
    assert_predicate replayed, :replayed?,
      "a replay retains the original 201 and is identified by its response header"
  end

  # The creator names its runner: the field rides the
  # envelope when given and is absent when omitted — an absent field
  # leaves the host unbound (the kernel infers no runner); a null one is
  # never sent.
  def test_create_names_the_runner_only_when_asked
    conversations([[201, {}, contract.fetch("valid_fixture")]])
      .create(idempotency_key: "key-1", default_runner_executor_public_id: "0199-runner")
    fields = request.fetch(:body).fetch("conversation")
    assert_equal "0199-runner", fields.fetch("default_runner_executor_public_id")

    conversations([[201, {}, contract.fetch("valid_fixture")]]).create(idempotency_key: "key-2")
    refute request.fetch(:body).fetch("conversation").key?("default_runner_executor_public_id"),
      "an omitted runner sends nothing: the host starts unbound"
  end

  # The creator names its answerer: the field rides the
  # envelope when given and is absent when omitted — an absent field means
  # the creator answers its own conversation; the document reads the
  # stored fact back on both shapes.
  def test_create_names_the_answerer_only_when_asked
    created = conversations([[201, {}, contract.fetch("valid_fixture")]])
      .create(idempotency_key: "key-1", answering_user_public_id: "0199-agent")
    fields = request.fetch(:body).fetch("conversation")
    assert_equal "0199-agent", fields.fetch("answering_user_public_id")
    assert_equal contract.dig("valid_fixture", "conversation", "answering_user_public_id"),
      created.conversation.answering_user_public_id

    conversations([[201, {}, contract.fetch("valid_fixture")]]).create(idempotency_key: "key-2")
    refute request.fetch(:body).fetch("conversation").key?("answering_user_public_id"),
      "an omitted answerer sends nothing: the creator answers"
  end

  # An empty key is the shape the signature admits and the SDK still
  # refuses: minting one silently is how a retry the caller cannot
  # recognize as a retry becomes a second conversation.
  def test_create_refuses_an_empty_idempotency_key
    assert_raises(ArgumentError) { conversations([]).create(idempotency_key: "") }
  end

  def test_the_full_read_carries_the_queue_the_cursor_and_provider_occupancy
    conversation = conversations([[200, {}, contract.fetch("valid_fixture")]]).fetch(CONVERSATION_ID)

    assert_equal 32, conversation.input_queue.limit
    refute_predicate conversation.input_queue, :full?
    assert_equal "Y3ZlaS03", conversation.latest_event_cursor
    assert_equal 3_120, conversation.context.used_tokens
    assert_equal "dev", conversation.context.as_of_model.provider_id
    assert_equal({ "topic" => "planning" }, conversation.metadata)
    refute_predicate conversation, :side?
    # The provider's own count of the prefix it served from cache; absent when it reported none.
    assert_equal contract.dig("valid_fixture", "conversation", "context", "cache_read_tokens"),
      conversation.context.cache_read_tokens
    assert_kind_of Integer, conversation.context.cache_read_tokens
  end

  def test_a_side_row_reads_as_side_and_a_context_without_a_cache_count_reads_nil
    fixture = contract.fetch("valid_fixture").fetch("conversation")
    body = { "conversation" => fixture.merge("side" => true,
      "context" => fixture.fetch("context").except("cache_read_tokens")) }
    conversation = conversations([[200, {}, body]]).fetch(CONVERSATION_ID)

    assert_predicate conversation, :side?
    assert_nil conversation.context.cache_read_tokens
  end

  # `context` is absent before the first settled turn, and that absence is
  # the honest answer — there is no provider count to report yet.
  def test_occupancy_absent_before_the_first_settled_turn_reads_as_nil
    body = { "conversation" => contract.fetch("valid_fixture").fetch("conversation").except("context") }
    conversation = conversations([[200, {}, body]]).fetch(CONVERSATION_ID)

    assert_nil conversation.context
  end

  def test_recorded_conversation_usage_is_typed_and_separate_from_latest_request_occupancy
    usage = { "request_count" => 3, "input_tokens" => 4_000, "cache_read_tokens" => 1_000,
      "uncached_input_tokens" => 3_000, "cache_creation_tokens" => 500, "cache_hit_rate" => 0.25,
      "output_tokens" => 400, "reasoning_tokens" => 100, "total_tokens" => 4_400,
      "cost_amount" => "0.123456789012345678", "cost_complete" => false, "cost_unit" => "credits" }
    body = { "conversation" => contract.fetch("valid_fixture").fetch("conversation").merge("usage_summary" => usage) }
    conversation = chat([[200, {}, body]]).fetch

    assert_instance_of CybrosAgent::Api::ConversationUsageSummary, conversation.usage_summary
    assert_equal usage.transform_keys(&:to_sym), conversation.usage_summary.to_h
    assert_equal 3_120, conversation.context.used_tokens
    assert_equal 4_400, conversation.usage_summary.total_tokens
    refute conversation.usage_summary.cost_complete
  end

  def test_zero_requests_have_complete_zero_cost_without_inventing_a_cache_ratio_or_unit
    usage = { "request_count" => 0, "input_tokens" => 0, "cache_read_tokens" => 0,
      "uncached_input_tokens" => 0, "cache_creation_tokens" => 0, "output_tokens" => 0,
      "reasoning_tokens" => 0, "total_tokens" => 0, "cost_amount" => "0.0", "cost_complete" => true,
      "cost_unit" => nil }
    body = { "conversation" => contract.fetch("valid_fixture").fetch("conversation")
      .except("context").merge("usage_summary" => usage) }
    conversation = chat([[200, {}, body]]).fetch

    assert_equal 0, conversation.usage_summary.request_count
    assert_equal "0.0", conversation.usage_summary.cost_amount
    assert conversation.usage_summary.cost_complete
    assert_nil conversation.usage_summary.cache_hit_rate
    assert_nil conversation.usage_summary.cost_unit
    assert_nil conversation.context
  end

  def test_full_conversation_reads_require_the_recorded_usage_summary
    body = { "conversation" => contract.fetch("valid_fixture").fetch("conversation").except("usage_summary") }
    assert_raises(CybrosAgent::Api::MalformedResponse) { chat([[200, {}, body]]).fetch }
  end

  # --- one conversation -----------------------------------------------

  def test_lifecycle_verbs_are_named_posts_and_delete_is_the_tombstone
    chat([[200, {}, contract.fetch("valid_fixture")]]).archive
    assert_equal "#{PATH}/archive", request.fetch(:path)

    chat([[200, {}, contract.fetch("valid_fixture")]]).unarchive
    assert_equal "#{PATH}/unarchive", request.fetch(:path)

    assert_nil chat([[204, {}, nil]]).delete
    assert_equal :delete, request.fetch(:method)
    assert_equal PATH, request.fetch(:path)
  end

  def test_update_refuses_an_empty_change_rather_than_sending_one
    assert_raises(ArgumentError) { chat([]).update }
  end

  def test_cancel_posts_the_cancellation_resource
    assert_nil chat([[202, {}, nil]]).cancel
    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/cancellation", request.fetch(:path)
  end

  # Replacing the default returns the conversation with its new selection.
  def test_set_default_runner_puts_the_default_and_answers_the_conversation_carrying_it
    bound = contract.fetch("valid_fixture").fetch("conversation").merge(
      "default_runner" => { "executor_public_id" => "019f0000-0000-7000-8000-000000000701",
                    "display_name" => "lab-mac", "presence" => "offline",
                    "last_seen_at" => "2026-09-08T10:00:00Z" }
    )
    conversation = chat([[200, {}, { "conversation" => bound }]])
      .set_default_runner(executor_public_id: "019f0000-0000-7000-8000-000000000701")

    assert_equal :put, request.fetch(:method)
    assert_equal "#{PATH}/default_runner", request.fetch(:path)
    assert_equal({ "default_runner" => { "executor_public_id" => "019f0000-0000-7000-8000-000000000701" } },
      request.fetch(:body))
    assert_instance_of CybrosAgent::Api::DefaultRunner, conversation.default_runner
    assert_equal "019f0000-0000-7000-8000-000000000701", conversation.default_runner.executor_public_id
    assert_equal "lab-mac", conversation.default_runner.display_name
    assert_equal "offline", conversation.default_runner.presence
    assert_equal "2026-09-08T10:00:00Z", conversation.default_runner.last_seen_at
    refute_predicate conversation.default_runner, :online?
  end

  def test_set_default_runner_refuses_an_empty_id_before_it_reaches_the_wire
    assert_raises(ArgumentError) { chat([]).set_default_runner(executor_public_id: "") }
  end

  # The two refusals are the plane's own codes, carried on the typed errors
  # the dispatch already maps: no new class for a new word.
  def test_set_default_runner_relays_the_kernels_two_refusals_by_code
    error = assert_raises(CybrosAgent::Api::Conflict) do
      chat([[409, {}, { "error" => { "code" => "runner_not_eligible", "message" => "revoked" } }]])
        .set_default_runner(executor_public_id: "019f0000-0000-7000-8000-000000000701")
    end
    assert_equal "runner_not_eligible", error.code
    assert_includes error.message, "revoked"

    error = assert_raises(CybrosAgent::Api::NotFound) do
      chat([[404, {}, { "error" => { "code" => "runner_not_found", "message" => "no" } }]])
        .set_default_runner(executor_public_id: "019f0000-0000-7000-8000-000000000701")
    end
    assert_equal "runner_not_found", error.code
  end

  # The read is OPTIONAL: a document with no key (an older Nexus) and one
  # with an explicit null (unbound, or reaped — the pack's own fixture)
  # both read as no binding.
  def test_the_runner_read_is_nil_when_absent_and_when_null
    fixture = contract.fetch("valid_fixture").fetch("conversation")
    assert fixture.key?("default_runner"), "the presenter always renders the binding"
    assert_nil fixture.fetch("default_runner"), "the pack's conversation is unbound"

    assert_nil chat([[200, {}, { "conversation" => fixture.except("default_runner") }]]).fetch.default_runner
    assert_nil chat([[200, {}, { "conversation" => fixture }]]).fetch.default_runner
  end

  # --- durable memory -------------------------------------------------

  DOC = {
    "public_id" => "019f0000-0000-7000-8000-000000000901", "lock_version" => 2,
    "path" => "workspace/notes.md", "bytesize" => 12,
    "written_at" => "2026-08-31T00:00:00Z",
  }.freeze

  # A SKILL ROW ON THE WORKSPACE RUNG, through the
  # room's conversation door: the pack's skill document, its description
  # on the wire and back, the refusal a missing description earns.
  def test_a_workspace_skill_is_written_with_its_description_through_the_conversation_door
    pack = CybrosAgentTest::ContractFixtures.pack("memory_documents.json")
    fixture = pack.fetch("valid_skill_fixture")
    fields = pack.fetch("valid_skill_write_request").fetch("memory")

    doc = chat([[201, {}, fixture]]).memory.write(fields.fetch("path"), fields.fetch("content"),
      expected_public_id: fields.fetch("expected_public_id"), expected_lock_version: fields.fetch("expected_lock_version"),
      description: fields.fetch("description"))
    assert_equal "#{PATH}/memory", request.fetch(:path)
    assert_equal({ "memory" => fields }, request.fetch(:body))
    assert_equal fixture.dig("memory", "description"), doc.description
    assert_equal fixture.dig("memory", "content"), doc.content
    assert_predicate doc, :skill?

    refusal = pack.fetch("valid_error_fixture")
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      chat([[refusal.fetch("status"), refusal.fetch("headers"), refusal.fetch("body")]])
        .memory.write("workspace/skills/commit-style", "x", expected_public_id: nil, expected_lock_version: nil)
    end
    assert_equal "skill_description_required", error.code
  end

  def test_the_listing_reports_sizes_and_ages_without_loading_content
    docs = chat([[200, {}, { "memory" => [DOC] }]]).memory.list

    assert_equal "#{PATH}/memory", request.fetch(:path)
    assert_equal "workspace/notes.md", docs.first.path
    assert_equal "workspace", docs.first.scope
    assert_equal 12, docs.first.bytesize
    assert_equal DOC.fetch("public_id"), docs.first.public_id
    assert_equal 2, docs.first.lock_version
    assert_nil docs.first.content,
      "a listing selects on bytesize precisely so it never loads what it is counting"
  end

  # THE PATH RIDES THE BODY on every verb that names one, reads included:
  # it carries its scope as a slash-separated first segment, which no
  # routing convention survives.
  def test_reading_one_document_posts_its_path_rather_than_encoding_it
    doc = chat([[200, {}, { "memory" => DOC.merge("content" => "the plan") }]])
      .memory.read("workspace/notes.md")

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/memory/show", request.fetch(:path)
    assert_equal({ "memory" => { "path" => "workspace/notes.md" } }, request.fetch(:body))
    assert_equal "the plan", doc.content
  end

  # The conditions belong to the read used to prepare the replacement.
  def test_a_write_replaces_the_whole_document_and_answers_it
    doc = chat([[201, {}, { "memory" => DOC.merge("content" => "new plan") }]])
      .memory.write("workspace/notes.md", "new plan", expected_public_id: DOC.fetch("public_id"), expected_lock_version: 1)

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/memory", request.fetch(:path)
    assert_equal "new plan", request.fetch(:body).fetch("memory").fetch("content")
    assert_equal DOC.fetch("public_id"), request.dig(:body, "memory", "expected_public_id")
    assert_equal 1, request.dig(:body, "memory", "expected_lock_version")
    refute request.fetch(:headers).key?("Idempotency-Key")
    assert_equal "new plan", doc.content
    assert_equal 2, doc.lock_version
  end

  def test_delete_is_a_post_with_the_path_and_answers_nothing
    assert_nil chat([[204, {}, nil]]).memory.delete("workspace/notes.md",
      expected_public_id: DOC.fetch("public_id"), expected_lock_version: 2)

    assert_equal "#{PATH}/memory/delete", request.fetch(:path)
    assert_equal({ "memory" => { "path" => "workspace/notes.md",
                                "expected_public_id" => DOC.fetch("public_id"), "expected_lock_version" => 2 } }, request.fetch(:body))
  end

  def test_a_stale_memory_write_surfaces_the_conflict_without_reading_or_retrying
    door = chat([[409, {}, { "error" => { "code" => "stale_object", "message" => "Read the current document." } }]]).memory
    error = assert_raises(CybrosAgent::Api::Conflict) do
      door.write("workspace/notes.md", "old calculation", expected_public_id: DOC.fetch("public_id"), expected_lock_version: 1)
    end

    assert_equal "stale_object", error.code
    assert_equal 1, @transport.requests.length
    assert_equal 1, request.dig(:body, "memory", "expected_lock_version")
    assert_equal "old calculation", request.dig(:body, "memory", "content")
  end

  # --- the conversation's own store ---------------------------
  #
  # `chat.store_entries` is this conversation's client state: the same
  # context the workspace handle answers, bound to the conversation's own
  # route. It forks with the conversation, and no prompt ever reads it —
  # which is the test that makes it a store and not memory.

  def store_pack = CybrosAgentTest::ContractFixtures.pack("store_entries.json")

  def test_the_conversations_store_lists_under_its_own_route
    page = chat([[200, {}, store_pack.fetch("valid_list_fixture")]]).store_entries.list

    assert_equal :get, request.fetch(:method)
    assert_equal "#{PATH}/store_entries", request.fetch(:path)
    assert_instance_of CybrosAgent::Api::StoreEntrySummary, page.items.first
  end

  def test_creating_a_conversation_entry_posts_the_envelope_under_the_callers_key
    fixture = store_pack.fetch("valid_fixture").fetch("store_entry")
    entry = chat([[201, {}, { "store_entry" => fixture }]]).store_entries
      .create(namespace: fixture.fetch("namespace"), key: fixture.fetch("key"), value: nil,
        idempotency_key: "key-1").store_entry

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/store_entries", request.fetch(:path)
    assert_equal "key-1", request.fetch(:headers).fetch("Idempotency-Key")
    assert_equal(
      { "store_entry" => {
        "namespace" => fixture.fetch("namespace"), "key" => fixture.fetch("key"), "value" => nil,
      } },
      request.fetch(:body)
    )
    assert_equal fixture.fetch("public_id"), entry.public_id
  end

  # --- the access carrier --------------------------------------

  # THE CARRIER IS ALWAYS PRESENT: the pack pins the key, and the document
  # reads it strictly — the default, and each entry's four members. A
  # document without it is a wrong shape, never "nobody restricted".
  def test_the_full_read_carries_the_access_carrier_and_refuses_its_absence
    conversation = chat([[200, {}, contract.fetch("valid_fixture")]]).fetch
    access = conversation.access

    assert_instance_of CybrosAgent::Api::ConversationAccess, access
    assert_equal "read", access.default
    assert_equal 1, access.entries.length
    entry = access.entries.fetch(0)
    assert_instance_of CybrosAgent::Api::ConversationAccessEntry, entry
    assert_equal %w[01900000-0000-7000-8000-000000000004 reviewer human Reviewer full],
      [entry.user_public_id, entry.handle, entry.kind, entry.display_name, entry.level]
    assert_equal "full", access.level_for(entry.user_public_id)
    assert_equal "read", access.level_for("01900000-0000-7000-8000-000000000099"), "the default covers everyone else"
    assert_predicate access.entries, :frozen?

    stripped = { "conversation" => contract.dig("valid_fixture", "conversation").except("access") }
    assert_raises(CybrosAgent::Api::MalformedResponse) { chat([[200, {}, stripped]]).fetch }
  end

  # The carrier at birth rides the create envelope when given, in the
  # order given, with the wire's spellings; omitted, nothing is sent and
  # the conversation is born `full`.
  def test_create_sends_the_access_carrier_only_when_asked_and_keeps_the_entries_order
    conversations([[201, {}, contract.fetch("valid_fixture")]]).create(
      idempotency_key: "key-1",
      access: { default: "none", entries: [{ user_public_id: "0199-b", level: "read" }, { user_public_id: "0199-a", level: "full" }] }
    )
    assert_equal contract.dig("valid_access_request", "access").keys.sort,
      request.fetch(:body).dig("conversation", "access").keys.sort
    assert_equal({ "default" => "none", "entries" => [
      { "user_public_id" => "0199-b", "level" => "read" }, { "user_public_id" => "0199-a", "level" => "full" },
    ] }, request.fetch(:body).dig("conversation", "access"))

    # A principal may be named by handle instead: the entry
    # rides as spelled, `@` and all — the kernel resolves it.
    conversations([[201, {}, contract.fetch("valid_fixture")]]).create(
      idempotency_key: "key-1b", access: { default: "none", entries: [{ handle: "@lark", level: "read" }] }
    )
    assert_equal({ "default" => "none", "entries" => [{ "handle" => "@lark", "level" => "read" }] },
      request.fetch(:body).dig("conversation", "access"))

    conversations([[201, {}, contract.fetch("valid_fixture")]]).create(idempotency_key: "key-2", access: { default: "none" })
    assert_equal({ "default" => "none" }, request.fetch(:body).dig("conversation", "access"), "no entries key when none given")

    conversations([[201, {}, contract.fetch("valid_fixture")]]).create(idempotency_key: "key-3")
    refute request.fetch(:body).fetch("conversation").key?("access"), "omitted sends nothing: born full"

    assert_raises(ArgumentError) { conversations([]).create(idempotency_key: "key-4", access: { entries: ["0199-a"] }) }
  end

  def test_access_write_shape_rejects_nonobjects_before_dispatch
    [nil, "none", [["default", "none"]]].each do |access|
      resource = conversations([])
      if ENV["RBS_TEST_TARGET"]
        # Runtime signatures reject the outer type before the Ruby guard.
        assert_raises(RBS::Test::Tester::TypeError) { resource.create(idempotency_key: "bad-access", access: access) }
      else
        error = assert_raises(ArgumentError) { resource.create(idempotency_key: "bad-access", access: access) }
        assert_equal "access must be a Hash of default: and entries:", error.message
      end
      assert_empty @transport.requests
    end

    [nil, "0199-a", [["handle", "@lark"], ["level", "read"]]].each do |entry|
      resource = conversations([])
      error = assert_raises(ArgumentError) { resource.create(idempotency_key: "bad-entry", access: { entries: [entry] }) }
      assert_equal "each access entry must be a Hash of user_public_id: (or handle:) and level:", error.message
      assert_empty @transport.requests
    end
  end

  # THE LATER CHANGE: a whole replacement, PUT on the nested singular
  # `access`, answered with the conversation carrying the carrier it now
  # has; entries omitted is the empty set.
  def test_set_access_puts_the_whole_set_and_answers_the_conversation_carrying_it
    conversation = chat([[200, {}, contract.fetch("valid_fixture")]])
      .set_access(default: "none", entries: [{ user_public_id: "0199-b", level: "read" }])

    assert_equal :put, request.fetch(:method)
    assert_equal "#{PATH}/access", request.fetch(:path)
    assert_equal({ "access" => { "default" => "none", "entries" => [{ "user_public_id" => "0199-b", "level" => "read" }] } },
      request.fetch(:body))
    assert_equal "read", conversation.access.default

    chat([[200, {}, contract.fetch("valid_fixture")]]).set_access(default: "full")
    assert_equal({ "access" => { "default" => "full", "entries" => [] } }, request.fetch(:body))

    chat([[200, {}, contract.fetch("valid_fixture")]]).set_access(default: "none", entries: [{ handle: "lark", level: "full" }])
    assert_equal({ "access" => { "default" => "none", "entries" => [{ "handle" => "lark", "level" => "full" }] } },
      request.fetch(:body), "by handle, as spelled")

    assert_raises(ArgumentError) { chat([]).set_access(default: "") }
  end

  # The refusals are the plane's own codes on the typed errors the
  # dispatch already maps: one code for an ineligible principal, the
  # family 403 for a principal short of full.
  def test_set_access_relays_the_kernels_refusals_by_code
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      chat([[422, {}, { "error" => { "code" => "principal_not_eligible", "message" => "Refused: principal_not_eligible" } }]])
        .set_access(default: "none", entries: [{ user_public_id: "0199-me", level: "full" }])
    end
    assert_equal "principal_not_eligible", error.code

    error = assert_raises(CybrosAgent::Api::Forbidden) do
      chat([[403, {}, { "error" => { "code" => "not_authorized", "message" => "no" } }]]).set_access(default: "full")
    end
    assert_equal "not_authorized", error.code
  end
end
