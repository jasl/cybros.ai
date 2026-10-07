require "test_helper"
require_relative "../support/contract_fixtures"

# The profile's standing declaration, written whole by the
# profile itself and read back on the bootstrap read; a human's profile
# carries no block, and the SDK says so with nil rather than an empty shape.
class ApiProfileTest < Minitest::Test
  BASH = {
    "type" => "function",
    "function" => { "name" => "bash", "description" => "Run a command",
                    "parameters" => { "type" => "object", "properties" => {} } },
  }.freeze
  # THE RULE LIST: the fifth column of the declaration, one
  # JSON array the SDK carries opaque — the kernel is the one evaluator.
  RULES = [
    { "tool" => "bash", "path" => "command", "match" => "*rm -rf /*", "verdict" => "deny",
      "reason" => "a person can run it" },
    { "tool" => "memory_*|ask|task|code", "verdict" => "allow" },
  ].freeze
  CONFIGURATION = {
    "tool_definitions" => [BASH], "kernel_tools" => [], "runner_executor_public_ids" => [],
    "runner_tool_names" => nil, "approval_mode" => "bypass", "approval_rules" => RULES,
    "prompt_mechanism" => "default", "prompt_template" => nil,
    "compaction_policy" => { "mode" => "kernel" }, "default_model" => "openrouter/fixture/priced",
    "lifecycle_hooks" => nil, "fallback_model" => "openrouter/fixture/fallback",
  }.freeze
  AGENT_BODY = {
    "member" => { "public_id" => "019f-agent", "handle" => "helper", "kind" => "agent", "role" => "member",
                  "display_name" => "Helper" },
    "credential" => { "plane" => "member", "expires_at" => nil },
    "configuration" => CONFIGURATION,
    "measured_at" => "2026-09-05T00:00:00Z",
  }.freeze
  HUMAN_BODY = {
    "member" => { "public_id" => "019f-human", "handle" => "owner", "kind" => "human", "role" => "owner",
                  "display_name" => "Owner" },
    "credential" => { "plane" => "member", "expires_at" => nil },
    "measured_at" => "2026-09-05T00:00:00Z",
  }.freeze

  def profile(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).profile
  end

  def request = @transport.requests.fetch(0)

  def test_an_agent_reads_its_declaration_back
    read = profile([[200, {}, AGENT_BODY]]).fetch

    assert_equal "/agent_api/v1/profile", request.fetch(:path)
    assert_equal "helper", read.member.handle, "the member's handle rides the profile"
    assert_raises(CybrosAgent::Api::MalformedResponse, "the handle is pinned present") do
      profile([[200, {}, AGENT_BODY.merge("member" => AGENT_BODY.fetch("member").except("handle"))]]).fetch
    end
    configuration = read.configuration
    assert_equal [BASH], configuration.tool_definitions
    assert_predicate configuration.tool_definitions, :frozen?, "a snapshot, never a live handle"
    assert_equal [], configuration.kernel_tools
    assert_equal [], configuration.runner_executor_public_ids
    assert_nil configuration.runner_tool_names
    assert_equal "bypass", configuration.approval_mode
    assert_equal RULES, configuration.approval_rules
    assert_predicate configuration.approval_rules, :frozen?, "the rule list is a snapshot too"
    assert_equal "default", configuration.prompt_mechanism
    assert_nil configuration.prompt_template
    assert_equal({ "mode" => "kernel" }, configuration.compaction_policy)
    assert_equal "openrouter/fixture/priced", configuration.default_model, "the seventh column, a catalog ref"
    assert_equal "openrouter/fixture/fallback", configuration.fallback_model, "the ninth, the model a refusal re-runs on"
  end

  def test_a_human_profile_has_no_declaration
    assert_nil profile([[200, {}, HUMAN_BODY]]).fetch.configuration
  end

  def test_lifecycle_hooks_are_declared_and_read_without_client_side_interpretation
    hooks = { "stop" => { "tool" => "verify", "timeout_ms" => 30_000, "max_continuations" => 2 } }
    body = AGENT_BODY.merge("configuration" => CONFIGURATION.merge("lifecycle_hooks" => hooks))
    read = profile([[200, {}, body]]).declare_configuration(
      tool_definitions: [BASH], approval_mode: "bypass", approval_rules: RULES,
      prompt_mechanism: "default", compaction_policy: nil, lifecycle_hooks: hooks
    )

    assert_equal hooks, request.fetch(:body).dig("configuration", "lifecycle_hooks")
    assert_equal hooks, read.configuration.lifecycle_hooks
    assert_predicate read.configuration.lifecycle_hooks, :frozen?
  end

  def test_an_undeclared_agent_reads_an_empty_block
    body = AGENT_BODY.merge("configuration" => {
      "tool_definitions" => [], "kernel_tools" => [], "runner_executor_public_ids" => [],
      "runner_tool_names" => nil, "approval_mode" => nil, "approval_rules" => nil,
      "prompt_mechanism" => nil, "prompt_template" => nil, "compaction_policy" => nil,
    })
    configuration = profile([[200, {}, body]]).fetch.configuration

    assert_equal [], configuration.tool_definitions
    assert_nil configuration.approval_mode
    assert_nil configuration.approval_rules, "no rules reads nil, never an empty list"
    assert_nil configuration.compaction_policy
    assert_nil configuration.default_model, "no preset reads nil"
    assert_nil configuration.fallback_model, "no fallback reads nil"
  end

  # Whole replacement: every field rides, nil included, so a field the
  # caller did not name is cleared rather than kept by accident.
  def test_the_declaration_is_put_whole_and_answers_the_profile
    read = profile([[200, {}, AGENT_BODY]]).declare_configuration(
      tool_definitions: [BASH], approval_mode: "bypass", approval_rules: RULES,
      prompt_mechanism: "default", compaction_policy: { "mode" => "kernel" },
      default_model: "openrouter/fixture/priced", fallback_model: "openrouter/fixture/fallback"
    )

    assert_equal :put, request.fetch(:method)
    assert_equal "/agent_api/v1/profile/configuration", request.fetch(:path)
    assert_equal({ "configuration" => CONFIGURATION, "prompt_documents" => nil }, request.fetch(:body))
    assert_equal "019f-agent", read.member.public_id
    assert_equal [BASH], read.configuration.tool_definitions
  end

  def test_tool_sources_preserve_canonical_names_candidate_order_and_runner_selection
    sources = {
      "kernel_tools" => ["nexus.graph.delegate_task", "nexus.memory.read"],
      "runner_executor_public_ids" => ["01900000-0000-7000-8000-000000000052", "01900000-0000-7000-8000-000000000051"],
      "runner_tool_names" => ["read", "grep"],
    }
    body = AGENT_BODY.merge("configuration" => CONFIGURATION.merge(sources))
    read = profile([[200, {}, body]]).declare_configuration(
      tool_definitions: [BASH], kernel_tools: sources.fetch("kernel_tools"),
      runner_executor_public_ids: sources.fetch("runner_executor_public_ids"),
      runner_tool_names: sources.fetch("runner_tool_names"), approval_mode: "bypass", approval_rules: RULES,
      prompt_mechanism: "default", compaction_policy: nil
    )

    sources.each do |name, value|
      assert_equal value, request.fetch(:body).fetch("configuration").fetch(name)
      assert_equal value, read.configuration.public_send(name)
      assert_predicate read.configuration.public_send(name), :frozen?
    end
  end

  def test_empty_runner_tool_names_remains_distinct_from_importing_all_tools
    body = AGENT_BODY.merge("configuration" => CONFIGURATION.merge("runner_tool_names" => []))
    read = profile([[200, {}, body]]).declare_configuration(
      tool_definitions: [], approval_mode: "bypass", approval_rules: nil,
      prompt_mechanism: "default", compaction_policy: nil, runner_tool_names: []
    )

    assert_equal [], request.fetch(:body).dig("configuration", "kernel_tools")
    assert_equal [], request.fetch(:body).dig("configuration", "runner_executor_public_ids")
    assert_equal [], request.fetch(:body).dig("configuration", "runner_tool_names")
    assert_equal [], read.configuration.runner_tool_names
  end

  def test_the_profile_slots_travel_with_configuration_in_one_request
    documents = {
      "system_prompt" => { "content" => "You are {{agent}}.", "role" => "developer" },
      "summarizer" => { "content" => "Keep result pointers." },
    }
    profile([[200, {}, AGENT_BODY]]).declare_configuration(
      tool_definitions: [BASH], approval_mode: "bypass", approval_rules: RULES,
      prompt_mechanism: "default", compaction_policy: { "mode" => "kernel" }, prompt_documents: documents
    )

    assert_equal documents, request.fetch(:body).fetch("prompt_documents")
    assert_equal 1, @transport.requests.length
  end

  # THE ASSEMBLY TEMPLATE: the profile's block list rides the
  # same PUT as the sixth column, whole and opaque — the kernel's grammar
  # judges it — and reads back as a frozen snapshot on the declaration.
  def test_the_template_rides_the_declaration_whole_and_reads_back_frozen
    template = { "blocks" => [{ "type" => "slot", "slot" => "system_prompt" }, { "type" => "history" },
                              { "type" => "input" }], "variables" => { "scene" => "an ordinary day" } }
    declared = CONFIGURATION.merge("prompt_mechanism" => "assembly", "prompt_template" => template)
    read = profile([[200, {}, AGENT_BODY.merge("configuration" => declared)]]).declare_configuration(
      tool_definitions: [BASH], approval_mode: "bypass", approval_rules: RULES,
      prompt_mechanism: "assembly", prompt_template: template, compaction_policy: { "mode" => "kernel" }
    )

    assert_equal template, request.fetch(:body).dig("configuration", "prompt_template")
    assert_equal template, read.configuration.prompt_template
    assert_predicate read.configuration.prompt_template, :frozen?
    assert_predicate read.configuration.prompt_template.fetch("blocks"), :frozen?
  end

  # THE RULE LIST IS REQUIRED IN THE SIGNATURE, like the four beside it:
  # a whole replacement that could omit it would silently clear the
  # policy, so the omission is an ArgumentError before any request.
  def test_the_declaration_names_its_rule_list_or_does_not_leave_the_process
    skip("the RBS hook answers before Ruby's own ArgumentError") if ENV["RBS_TEST_TARGET"]

    context = profile([])
    assert_raises(ArgumentError) do
      context.declare_configuration(tool_definitions: [BASH], approval_mode: "ask",
        prompt_mechanism: "default", compaction_policy: nil)
    end
    assert_empty @transport.requests, "nothing reached the wire"
  end

  # The kernel is the one evaluator of the grammar: a malformed
  # rule is refused by name as `validation_failed`, typed at the seam, and
  # this SDK never pre-parses the list.
  def test_a_malformed_rule_is_validation_failed
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      profile([[422, {}, { "error" => { "code" => "validation_failed",
                                        "message" => "Approval rules has a rule with the unknown key scope" } }]])
        .declare_configuration(tool_definitions: [BASH], approval_mode: "rules",
          approval_rules: [{ "tool" => "bash", "verdict" => "deny", "scope" => "all" }],
          prompt_mechanism: "default", compaction_policy: nil)
    end

    assert_equal "validation_failed", error.code
    assert_equal [{ "tool" => "bash", "verdict" => "deny", "scope" => "all" }],
      request.fetch(:body).dig("configuration", "approval_rules"), "sent as written; the kernel judged it"
  end

  def test_a_malformed_block_is_refused_at_the_seam
    body = AGENT_BODY.merge("configuration" => { "approval_mode" => "bypass" })

    assert_raises(CybrosAgent::Api::MalformedResponse) { profile([[200, {}, body]]).fetch }
  end

  # --- the person's own memory scope -------------------------
  #
  # `client.profile.memory` is the `user/` door: the same four verbs the
  # conversation door serves, over the caller's controlling Human's own
  # scope, reachable from any workspace. The path rides the body here too.

  USER_DOC = {
    "public_id" => "019f0000-0000-7000-8000-000000000902", "lock_version" => 0,
    "path" => "user/notes.md", "bytesize" => 9,
    "written_at" => "2026-09-07T00:00:00Z",
  }.freeze

  # A SKILL ROW AT THE PERSON'S DOOR: `description`
  # rides the write only when given and comes back on both shapes; a plain
  # document's write carries no description.
  def test_a_user_skill_is_written_with_its_description_and_read_back_with_it
    skill = memory_pack.fetch("valid_skill_fixture").fetch("memory").merge("path" => "user/skills/review-checklist")
    request_fields = memory_pack.fetch("valid_skill_write_request").fetch("memory")
    doc = profile([[201, {}, { "memory" => skill }]])
      .memory.write("user/skills/review-checklist", request_fields.fetch("content"),
        expected_public_id: request_fields.fetch("expected_public_id"), expected_lock_version: request_fields.fetch("expected_lock_version"),
        description: request_fields.fetch("description"))

    assert_equal({ "memory" => request_fields.merge("path" => "user/skills/review-checklist") }, request.fetch(:body))
    assert_equal request_fields.fetch("description"), doc.description
    assert_predicate doc, :skill?
    assert_equal "user", doc.scope

    plain = profile([[201, {}, { "memory" => USER_DOC.merge("content" => "n") }]]).memory.write("user/notes.md", "n",
      expected_public_id: nil, expected_lock_version: nil)
    assert_equal({ "memory" => { "path" => "user/notes.md", "content" => "n",
                                "expected_public_id" => nil, "expected_lock_version" => nil } }, request.fetch(:body),
      "a plain write carries no description key at all")
    assert_nil plain.description
    refute_predicate plain, :skill?

    listed = profile([[200, {}, memory_pack.fetch("valid_list_fixture")]]).memory.list
    assert_equal [true, false], listed.map(&:skill?)
    assert_equal ["How I review a change. Use before approving a pull request.", nil], listed.map(&:description)
  end

  def memory_pack = CybrosAgentTest::ContractFixtures.pack("memory_documents.json")

  def test_the_persons_memory_lists_under_the_profile
    docs = profile([[200, {}, { "memory" => [USER_DOC] }]]).memory.list

    assert_equal "/agent_api/v1/profile/memory", request.fetch(:path)
    assert_equal :get, request.fetch(:method)
    assert_equal "user/notes.md", docs.first.path
    assert_equal "user", docs.first.scope
    assert_nil docs.first.content, "a listing carries sizes and ages, never text"
  end

  def test_reading_the_persons_document_posts_its_path
    doc = profile([[200, {}, { "memory" => USER_DOC.merge("content" => "the notes") }]])
      .memory.read("user/notes.md")

    assert_equal :post, request.fetch(:method)
    assert_equal "/agent_api/v1/profile/memory/show", request.fetch(:path)
    assert_equal({ "memory" => { "path" => "user/notes.md" } }, request.fetch(:body))
    assert_equal "the notes", doc.content
  end

  def test_writing_the_persons_document_replaces_it_whole
    doc = profile([[201, {}, { "memory" => USER_DOC.merge("content" => "new notes", "lock_version" => 1) }]])
      .memory.write("user/notes.md", "new notes", expected_public_id: USER_DOC.fetch("public_id"), expected_lock_version: 0)

    assert_equal :post, request.fetch(:method)
    assert_equal "/agent_api/v1/profile/memory", request.fetch(:path)
    assert_equal({ "memory" => { "path" => "user/notes.md", "content" => "new notes",
                                "expected_public_id" => USER_DOC.fetch("public_id"), "expected_lock_version" => 0 } },
      request.fetch(:body))
    refute request.fetch(:headers).key?("Idempotency-Key")
    assert_equal "new notes", doc.content
    assert_equal 1, doc.lock_version
  end

  def test_deleting_the_persons_document_posts_the_path_and_answers_nothing
    assert_nil profile([[204, {}, nil]]).memory.delete("user/notes.md",
      expected_public_id: USER_DOC.fetch("public_id"), expected_lock_version: 0)

    assert_equal "/agent_api/v1/profile/memory/delete", request.fetch(:path)
    assert_equal({ "memory" => { "path" => "user/notes.md",
                                "expected_public_id" => USER_DOC.fetch("public_id"), "expected_lock_version" => 0 } }, request.fetch(:body))
  end

  # --- the acting user's own slots ----------------------------
  #
  # `client.profile.prompt_documents` is the ACTING user's slot door: an
  # agent profile's `system_prompt` (its own row, never its steward's — rho
  # writes its guideline here at boot), a Human's `persona`. The same four
  # verbs as the workspace's `character` door, over the profile's path;
  # the other slots are refused here by name.

  PROMPT_PATH = "/agent_api/v1/profile/prompt_documents".freeze

  def prompt_pack = CybrosAgentTest::ContractFixtures.pack("prompt_documents.json")

  def test_the_acting_users_slots_list_under_the_profile
    docs = profile([[200, {}, prompt_pack.fetch("valid_list_fixture")]]).prompt_documents.list

    assert_equal :get, request.fetch(:method)
    assert_equal PROMPT_PATH, request.fetch(:path)
    assert_instance_of CybrosAgent::Api::PromptDocument, docs.first
    assert_nil docs.first.content, "a listing carries no text"
  end

  def test_reading_the_acting_users_slot_gets_its_member_path
    doc = profile([[200, {}, prompt_pack.fetch("valid_fixture")]]).prompt_documents.read("system_prompt")

    assert_equal :get, request.fetch(:method)
    assert_equal "#{PROMPT_PATH}/system_prompt", request.fetch(:path)
    assert_equal prompt_pack.dig("valid_fixture", "prompt_document", "content"), doc.content
  end

  def test_writing_the_acting_users_slot_puts_it_whole
    doc = profile([[200, {}, prompt_pack.fetch("valid_fixture")]]).prompt_documents
      .write("system_prompt", "Call several tools in one message.")

    assert_equal :put, request.fetch(:method)
    assert_equal "#{PROMPT_PATH}/system_prompt", request.fetch(:path)
    assert_equal({ "prompt_document" => { "content" => "Call several tools in one message." } },
      request.fetch(:body))
    assert_equal 2, doc.version
  end

  def test_deleting_the_acting_users_slot_answers_nothing
    assert_nil profile([[204, {}, nil]]).prompt_documents.delete("persona")

    assert_equal :delete, request.fetch(:method)
    assert_equal "#{PROMPT_PATH}/persona", request.fetch(:path)
  end

  def test_the_slot_the_profile_cannot_hold_is_refused_by_name
    unavailable = prompt_pack.fetch("valid_error_fixture")
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      profile([[unavailable.fetch("status"), {}, unavailable.fetch("body")]]).prompt_documents.write("character", "x")
    end
    assert_equal "prompt_slot_unavailable", error.code, "the room's character has its own door"
  end

  # --- the principal's own store ------------------------------
  #
  # `client.profile.store_entries` is the ACTING user's own row — an
  # agent's entries are the agent's, not its steward's, where memory's
  # `user/` is the controlling Human's. The door keeps no receipt: a
  # retried create is `Conflict key_taken`, never a replay.

  STORE_PATH = "/agent_api/v1/profile/store_entries".freeze

  def store_pack = CybrosAgentTest::ContractFixtures.pack("store_entries.json")

  def test_the_principals_store_lists_under_the_profile
    page = profile([[200, {}, store_pack.fetch("valid_list_fixture")]]).store_entries.list

    assert_equal :get, request.fetch(:method)
    assert_equal STORE_PATH, request.fetch(:path)
    assert_instance_of CybrosAgent::Api::StoreEntrySummary, page.items.first
  end

  def test_creating_the_principals_entry_posts_under_the_profile_with_the_key
    fixture = store_pack.fetch("valid_fixture").fetch("store_entry")
    entry = profile([[201, {}, { "store_entry" => fixture }]]).store_entries
      .create(namespace: fixture.fetch("namespace"), key: fixture.fetch("key"), value: nil,
        idempotency_key: "key-1")

    assert_equal :post, request.fetch(:method)
    assert_equal STORE_PATH, request.fetch(:path)
    assert_equal "key-1", request.fetch(:headers).fetch("Idempotency-Key")
    assert_equal(
      { "store_entry" => {
        "namespace" => fixture.fetch("namespace"), "key" => fixture.fetch("key"), "value" => nil,
      } },
      request.fetch(:body)
    )
    assert_equal fixture.fetch("public_id"), entry.public_id
  end

  def test_a_retried_create_at_the_profile_door_is_key_taken_not_a_replay
    error = assert_raises(CybrosAgent::Api::Conflict) do
      profile([[409, {}, { "error" => { "code" => "key_taken", "message" => "taken" } }]])
        .store_entries.create(namespace: "e2e", key: "own", value: nil, idempotency_key: "key-1")
    end

    assert_equal "key_taken", error.code
    assert_includes store_pack.fetch("error_codes"), "key_taken",
      "the code the profile door answers on a repeat is one the pack publishes"
  end
end
