require "test_helper"
require_relative "../support/contract_clients"

class ApiPublicContractPackTest < Minitest::Test
  include CybrosAgentTest::ContractClients

  def test_every_sdk_contract_has_valid_and_unknown_behavior_fixtures
    coverage = contract("coverage.json")

    coverage.each_value do |entries|
      entries.each do |name, entry|
        next unless entry.fetch("consumers").include?("sdk")

        refute_empty entry.fetch("unknown_behavior"), name
        refute_nil resolve(entry.fetch("valid_fixture")), name
        refute_nil resolve(entry.fetch("unknown_fixture")), name
      end
    end
  end

  def test_the_sdk_reader_rejects_an_unknown_pack_version
    meta = contract("meta.json")

    assert_raises(ArgumentError) do
      CybrosAgentTest::ContractFixtures.validate_version!(
        meta_contract: meta.fetch("unknown_version_fixture"),
        manifest_contract: CybrosAgentTest::ContractFixtures::CONTRACT
      )
    end
  end

  # THE UPLOAD PACK: one descriptor for the member and executor
  # doors alike, parsed through both real clients; the bytes read's
  # statuses; the commit fixture naming a capture rides `commit` verbatim,
  # and `ResourceLink#to_h` IS the pack's block.
  def test_the_upload_fixtures_parse_through_both_doors_and_the_link_block_matches_the_pack
    uploads = contract("uploads.json")
    descriptor = uploads.fetch("valid_fixture")

    staged = api_client(descriptor).uploads.fetch(descriptor.dig("upload", "public_id"))
    assert_instance_of CybrosAgent::Api::Upload, staged
    assert_equal descriptor.dig("upload", "content_type"), staged.content_type
    assert_equal uploads.fetch("descriptor_projection").sort, CybrosAgent::Api::Upload.members.map(&:to_s).sort

    transport = CybrosAgentTest::FakeTransport.new([[uploads.fetch("ingest_status"), {}, descriptor]])
    executor = CybrosAgent::ExecutorClient.new(base_url: "http://example.test",
      credential: "fixture-executor-token", transport: transport)
    captured = executor.uploads.create_io(StringIO.new("PNG"), filename: "shot.png")
    assert_equal staged, captured, "the executor door answers the member door's descriptor"
    assert_equal uploads.dig("ingest_paths", "executor"), transport.requests.fetch(0).fetch(:path)
    assert_equal CybrosAgent::Api::UploadsContext::PATH, uploads.dig("ingest_paths", "member")
    assert_equal CybrosAgent::Api::ExecutorUploadsContext::PATH, uploads.dig("ingest_paths", "executor")
    assert_equal({ "whole" => 200, "range" => 206, "fresh" => 304, "absent" => 404 }, uploads.fetch("bytes_statuses"))
    # THE TWO NAMED REPRESENTATION READS: the SDK's verbs are the
    # pack's paths, the 304 the pack names is the typed `unchanged?`, and
    # the refusal's code is a resource code the pack publishes.
    representations = uploads.fetch("representation_paths")
    assert_equal %w[preview thumbnail], representations.keys.sort
    sink_transport = CybrosAgentTest::FakeTransport.new([
      [uploads.dig("representation_statuses", "whole"), { "ETag" => '"t"' }, "PNG"],
      [uploads.dig("representation_statuses", "fresh"), {}, nil],
    ])
    reader = CybrosAgent::Client.new(base_url: "http://example.test", credential: "fixture-token",
      transport: sink_transport)
    public_id = descriptor.dig("upload", "public_id")
    read = reader.uploads.thumbnail(public_id, StringIO.new)
    assert_equal representations.fetch("thumbnail").sub("{public_id}", public_id),
      sink_transport.requests.fetch(0).fetch(:path)
    assert_equal uploads.dig("representation_statuses", "whole"), read.status
    assert_predicate reader.uploads.preview(public_id, StringIO.new, etag: read.etag), :unchanged?
    assert_equal representations.fetch("preview").sub("{public_id}", public_id),
      sink_transport.requests.fetch(1).fetch(:path)
    assert_equal 404, uploads.dig("error_statuses", "representation_unavailable")
    assert_match(/\Amax-age=\d+, private\z/, uploads.fetch("attachment_cache_control"))

    inbox = contract("executor_inbox.json")
    fixture = inbox.fetch("commit_link_fixture")
    block = fixture.fetch("content").fetch(1)
    assert_equal block, CybrosAgent::Api::ResourceLink.to_upload(
      block.fetch("uri").delete_prefix(inbox.fetch("resource_link_uri_prefix")),
      name: block.fetch("name"), mime_type: block["mimeType"], size: block["size"], title: block["title"]
    ).to_h, "the SDK's block is the pack's, field for field"
    assert_equal CybrosAgent::Api::ResourceLink::URI_PREFIX, inbox.fetch("resource_link_uri_prefix")
    assert_includes inbox.fetch("content_kinds"), CybrosAgent::Api::ResourceLink::TYPE
    assert_equal 422, inbox.dig("error_statuses", "unknown_result_upload")

    commit_transport = CybrosAgentTest::FakeTransport.new([[200, {}, { "task" => { "key" => "r1t0",
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "on_failure" => "absorb", "visibility" => "visible" } }]])
    CybrosAgent::ExecutorClient.new(base_url: "http://example.test", credential: "fixture-executor-token",
      transport: commit_transport)
      .inbox_task(agent_loop_public_id: "al-1", task_key: "r1t0")
      .commit(**fixture.transform_keys(&:to_sym))
    assert_equal fixture, commit_transport.requests.fetch(0).fetch(:body), "the fixture rides the commit verbatim"
  end

  # The announcement's one write shape: the pack's
  # request rides `announce` byte for byte — tools, environment, documents
  # — and discovery, rendered by the real presenter over it, parses
  # through the real client with the documents beside the tools.
  def test_the_announcement_request_and_the_discovery_fixture_ride_the_real_executor_surfaces
    executors = contract("task_executors.json")
    request = executors.fetch("announcement_request_fixture")
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, executors.fetch("valid_fixture")]])
    CybrosAgent::ExecutorClient.new(base_url: "http://example.test", credential: "fixture-executor-token",
      transport: transport)
      .announce(tools: request.fetch("tools"), environment: request.fetch("environment"),
        documents: request.fetch("documents"))
    assert_equal request, transport.requests.fetch(0).fetch(:body), "the fixture rides the announcement verbatim"

    discovery = executors.fetch("discovery_fixture")
    discovered = api_client("executors" => [discovery]).executors.list.fetch(0)
    assert_equal discovery.fetch("served_documents").map { |entry| entry.fetch("name") }, discovered.document_names
    assert_equal executors.fetch("served_document_keys"), discovery.fetch("served_documents").fetch(0).keys
    assert_equal discovery.fetch("served_documents"),
      discovered.served_documents.map { |document| document.to_h.transform_keys(&:to_s) }
    assert_equal discovery.fetch("served_tools").map { |entry| entry.fetch("name") }, discovered.tool_names
    assert_includes discovered.tool_names, "skill", "an address announcing documents announces skill"
  end

  # THE KERNEL TOOL CATALOG AS THE ROUTE SERVES IT: the pack carries `GET /tools`' whole listing through the one
  # presenter the route renders, so `Entry#template` is settled against the
  # kernel's bytes rather than a hand-written sample — every entry's source
  # is a String, and the plain `definition` names the same tool. A recut in
  # `CybrosAgent::ModelAdaptations` anchors on this text.
  def test_the_tool_listing_fixture_parses_through_the_real_client_with_every_template
    tools = contract("tools.json")
    listing = tools.fetch("valid_listing_fixture")
    entries = api_client(listing).tools.list

    assert_equal tools.fetch("listing_envelope"), listing.keys
    assert_equal listing.fetch("tools").length, entries.length
    refute_empty entries
    entries.zip(listing.fetch("tools")).each do |entry, served|
      assert_equal tools.fetch("entry_keys"), served.keys, "#{served.fetch("canonical_name")}: the served shape"
      assert_equal served.fetch("canonical_name"), entry.canonical_name
      assert_equal served.fetch("name"), entry.definition.dig("function", "name")
      assert_kind_of String, entry.template, "#{entry.canonical_name}: the kernel serves every source"
      assert_equal served.fetch("template"), entry.template
      assert_equal served.fetch("definition"), entry.definition
    end
    assert entries.any? { |entry| entry.template.include?("{{") },
      "the source carries macros the plain render spells out, or a recut has nothing to anchor on"
  end

  # THE SETTLED FIXTURE FOR A PACK ROW'S RENDER (memory: SDK shapes need a settled fixture): the
  # kernel's profile read after an application declared the pack's
  # `claude` row — generated by the kernel from a real render — parses
  # through the real client, and the row's entries as THIS loader renders
  # them (recuts against the served templates the tools pack carries) are
  # the fixture's alias blocks: the same names in order, the same
  # resolution facts beside each, and the recut's text as the kernel
  # stores it with every macro spelled in the set's own names.
  def test_the_alias_render_fixture_is_the_claude_row_as_the_kernel_stores_it
    fixture = contract("profiles.json").fetch("alias_render_fixture")
    stored = api_client(fixture).profile.fetch.configuration.tool_definitions
    pack = CybrosAgent::ModelAdaptations.load
    row = pack.row("claude")
    templates = contract("tools.json").fetch("valid_listing_fixture").fetch("tools")
      .to_h { |served| [served.fetch("canonical_name"), served.fetch("template")] }
    entries = pack.alias_entries(row, templates: templates)
    aliases = stored.select { |block| block.key?("canonical") }
    plain = stored.reject { |block| block.key?("canonical") }.map { |block| block.dig("function", "name") }
    names = ->(list) { list.map { |block| block.dig("function", "name") } }

    assert_equal %w[wait compose spawn send], plain, "the plain names the row keeps; task, ask and skill superseded"
    assert_equal names.call(entries), names.call(aliases), "the row's aliases, in the tables' order"
    spellings = pack.presets.plain.values.to_h { |name| [name, name] }
      .merge(entries.to_h { |entry| [pack.presets.plain_name(entry.fetch("canonical")), entry.dig("function", "name")] })
    entries.zip(aliases).each do |entry, block|
      name = entry.dig("function", "name")
      assert_equal entry.fetch("canonical"), block.fetch("canonical"), name
      assert_equal entry.fetch("params", {}), block.fetch("params", {}), "#{name}: the parameter map"
      assert_equal entry.fetch("omit", []), block.fetch("omit", []), "#{name}: the omitted kernel parameters"
      next unless entry.key?("description")

      spelled = entry.fetch("description").gsub(/\{\{([a-z_]+)\}\}/) { spellings.fetch(Regexp.last_match(1)) }
      assert_equal spelled, block.dig("function", "description"),
        "#{name}: the recut, rendered here against the served template, is what the kernel stored"
    end
    agent = aliases.find { |block| block.dig("function", "name") == "Agent" }
    assert_includes agent.dig("function", "description"), "`run_in_background: false` means your next round WAITS"
    assert_equal "wait", agent.dig("params", "run_in_background", "maps_to")
    assert agent.dig("params", "run_in_background", "invert")
  end

  # The inbox row and the claim answer are rendered by the real presenter
  # and read through the real executor client; a kind this gem predates
  # is carried, not refused.
  def test_the_executor_inbox_fixtures_parse_through_the_real_executor_client
    inbox = contract("executor_inbox.json")
    valid = inbox.fetch("valid_fixture")
    page = executor_client(valid).inbox.list
    row = valid.fetch("tasks").fetch(0)

    assert_equal 1, page.items.length
    task = page.items.fetch(0)
    assert_instance_of CybrosAgent::Api::InboxTask, task
    assert_equal "tool_call", task.kind
    assert_equal row.fetch("workspace_public_id"), task.workspace_public_id
    assert_equal row.fetch("task_key"), task.task_key
    assert_equal row.dig("addressed_to", "role"), task.addressed_to.role
    assert_equal row.dig("addressed_to", "executor_public_id"), task.addressed_to.executor_public_id
    assert_equal valid.dig("pagination", "next_after"), page.next_after
    assert_equal inbox.fetch("row_projection").sort, CybrosAgent::Api::InboxTask.members.map(&:to_s).sort,
      "the typed row carries exactly the presenter's projection"

    claim_fixture = inbox.fetch("claim_fixture")
    claimed = executor_client(claim_fixture)
      .inbox_task(agent_loop_public_id: row.fetch("agent_loop_public_id"), task_key: row.fetch("task_key"))
      .claim
    assert_instance_of CybrosAgent::Api::ClaimedTask, claimed
    assert_equal claim_fixture.dig("task", "workspace_public_id"), claimed.task.workspace_public_id
    assert_equal claim_fixture.dig("claim", "claim_token"), claimed.claim_token
    assert_predicate claimed.task, :claimed?

    unknown = executor_client(
      "tasks" => [inbox.fetch("unknown_kind_fixture")],
      "pagination" => { "next_after" => nil }
    ).inbox.list
    assert_equal inbox.fetch("unknown_value_fixture"), unknown.items.fetch(0).kind
  end

  # THE APPROVAL ROW: a tool call resting for an approver lists
  # on the addressed agent application's inbox as kind `approval` with the
  # frozen effect profile the approver reads — the one row kind that
  # carries it — `claimed: false` for as long as it stands, and a
  # deadline the park clock set; the valid runner row carries no profile.
  def test_the_packs_approval_fixture_parses_with_the_effect_profile_the_approver_reads
    inbox = contract("executor_inbox.json")
    fixture = inbox.fetch("approval_fixture")
    page = executor_client("tasks" => [fixture], "pagination" => { "next_after" => nil }).inbox.list

    row = page.items.fetch(0)
    assert_equal "approval", row.kind
    assert_equal fixture.fetch("workspace_public_id"), row.workspace_public_id
    assert_equal fixture.fetch("effect_profile"), row.effect_profile
    assert_predicate row.effect_profile, :frozen?
    assert_equal fixture.fetch("tool_name"), row.tool_name
    assert_equal fixture.fetch("tool_input"), row.tool_input
    assert_equal "agent_application", row.addressed_to.role
    refute_predicate row, :claimed?, "never claimed: the verbs are member-plane"
    assert_nil row.started_at, "a held row has not started"
    refute_nil row.deadline_at, "the park clock"

    runner_row = executor_client(inbox.fetch("valid_fixture")).inbox.list.items.fetch(0)
    assert_nil runner_row.effect_profile, "a runner row never carries the profile"
  end

  # The pack's OVERRIDDEN row parses through the real client from
  # both doors: the kernel's `scope` stamp rides the listing and the claim
  # as one frozen map keyed exactly by the pack's projection, `tool_input`
  # untouched beside it; the valid runner row of the pack carries no stamp.
  def test_the_packs_overridden_fixture_parses_with_its_scope_stamp
    inbox = contract("executor_inbox.json")
    fixture = inbox.fetch("overridden_fixture")
    page = executor_client("tasks" => [fixture], "pagination" => { "next_after" => nil }).inbox.list

    row = page.items.fetch(0)
    assert_equal fixture.fetch("scope"), row.scope
    assert_equal fixture.fetch("workspace_public_id"), row.workspace_public_id
    assert_equal inbox.fetch("memory_scope_projection").sort, row.scope.keys.sort
    assert_predicate row.scope, :frozen?
    assert_equal "tools_provider", row.addressed_to.role
    assert_equal fixture.fetch("tool_input"), row.tool_input
    assert_nil executor_client(inbox.fetch("valid_fixture")).inbox.list.items.fetch(0).scope,
      "the runner row of the pack carries no stamp"

    claim_fixture = inbox.fetch("claim_fixture")
    claimed = executor_client(claim_fixture.merge("task" => claim_fixture.fetch("task").merge(
      "tool_name" => fixture.fetch("tool_name"), "scope" => fixture.fetch("scope")
    ))).inbox_task(agent_loop_public_id: fixture.fetch("agent_loop_public_id"),
      task_key: fixture.fetch("task_key")).claim
    assert_equal fixture.fetch("scope"), claimed.task.scope
  end

  # The pack's ask row parses through the real client: the
  # question rides `prompt`, no tool field is present, and it is not claimed.
  def test_the_packs_ask_fixture_parses
    inbox = contract("executor_inbox.json")
    ask_fixture = inbox.fetch("ask_fixture")
    page = executor_client("tasks" => [ask_fixture], "pagination" => { "next_after" => nil }).inbox.list

    ask = page.items.fetch(0)
    assert_equal "ask", ask.kind
    assert_equal ask_fixture.fetch("workspace_public_id"), ask.workspace_public_id
    assert_equal ask_fixture.fetch("prompt"), ask.prompt
    assert_equal ask_fixture.fetch("options"), ask.options, "the choices ride the row as data (audit refs-parity-6)"
    assert_equal ask_fixture.fetch("multi"), ask.multi
    assert_nil ask.tool_name
    refute ask_fixture.key?("tool_name")
    refute_predicate ask, :claimed?
    assert_equal "agent_application", ask.addressed_to.role
  end

  # THE SOURCE-ROUTED ROW: a model's `skill {name}`
  # for a name this executor announced under `documents` reaches its inbox
  # as the same `skill` row — the kernel's `tool_name`, the model's alias
  # beside it, `tool_input` untouched, the scope stamp every kernel-named
  # row carries — and parses through the real client like the overridden row.
  def test_the_packs_skill_fixture_parses_as_a_kernel_named_runner_row_with_its_scope_stamp
    inbox = contract("executor_inbox.json")
    fixture = inbox.fetch("skill_fixture")
    page = executor_client("tasks" => [fixture], "pagination" => { "next_after" => nil }).inbox.list

    row = page.items.fetch(0)
    assert_equal "tool_call", row.kind
    assert_equal "skill", row.tool_name
    assert_equal fixture.fetch("workspace_public_id"), row.workspace_public_id
    assert_equal "Skill", row.tool_alias, "Claude Code's spelling rides beside the kernel's name"
    assert_nil executor_client(inbox.fetch("valid_fixture")).inbox.list.items.fetch(0).tool_alias,
      "a plain call carries none"
    assert_equal({ "name" => "deploy-notes" }, row.tool_input)
    assert_equal fixture.fetch("scope"), row.scope
    assert_equal inbox.fetch("scope_projection").sort, row.scope.keys.sort
    assert_equal "runner", row.addressed_to.role
    refute_predicate row, :claimed?
  end

  def test_the_six_executor_refusal_codes_are_family_codes_at_409
    errors = contract("errors.json")
    codes = %w[not_addressed_here already_claimed task_not_claimable not_claimable_kind stale_claim not_eligible]

    codes.each do |code|
      assert_includes errors.fetch("family_codes"), code
      assert_equal 409, errors.fetch("status_by_code").fetch(code), code

      transport = CybrosAgentTest::FakeTransport.new(
        [[409, {}, { "error" => { "code" => code, "message" => "Refused: #{code}" } }]]
      )
      door = CybrosAgent::ExecutorClient.new(
        base_url: "http://example.test", credential: "fixture-executor-token", transport: transport
      ).inbox_task(agent_loop_public_id: "fixture-loop", task_key: "r1t0")

      error = assert_raises(CybrosAgent::Api::Conflict, code) { door.claim }
      assert_equal code, error.code
    end
  end

  # DURABLE MEMORY AND THE SKILL ROW: the
  # pack's two documents are rendered by the real presenter and read
  # through the real context on both doors; the typed document carries
  # exactly the presenter's projection, `description` optional on both
  # shapes so a listing and a plain read parse alike.
  def test_the_memory_document_fixtures_parse_on_both_doors
    pack = contract("memory_documents.json")
    plain = pack.fetch("valid_fixture")
    skill = pack.fetch("valid_skill_fixture")

    doc = api_client(plain).workspace("fixture-workspace").conversation("fixture-conversation").memory
      .read(plain.dig("memory", "path"))
    assert_instance_of CybrosAgent::Api::MemoryDocument, doc
    assert_equal plain.dig("memory", "content"), doc.content
    assert_nil doc.description
    assert_equal (pack.fetch("basic_projection") + pack.fetch("full_projection_adds")).sort,
      CybrosAgent::Api::MemoryDocument.members.map(&:to_s).sort,
      "the typed document carries exactly the presenter's projection"

    loaded = api_client(skill).profile.memory.read(skill.dig("memory", "path"))
    assert_equal skill.dig("memory", "description"), loaded.description
    assert_predicate loaded, :skill?
    assert_includes pack.fetch("skill_anchors"), "workspace"
    assert_match Regexp.new(pack.fetch("skill_name_format")), "commit-style"
    refute_match Regexp.new(pack.fetch("skill_name_format")), "Commit"

    listed = api_client(pack.fetch("valid_list_fixture")).profile.memory.list
    assert_equal 2, listed.length
    assert listed.all? { |row| row.content.nil? }

    error_fixture = pack.fetch("valid_error_fixture")
    assert_equal pack.fetch("error_statuses").fetch(error_fixture.dig("body", "error", "code")),
      error_fixture.fetch("status")
    assert_includes pack.fetch("error_codes"), "skill_description_required"
  end

  # THE PROMPT DOCUMENTS: the pack's document is rendered by the
  # real presenter and read through the real context on both doors; the
  # slot and role words are the KERNEL's closed vocabulary — the reader
  # rejects nothing by vocabulary, as the executor inbox precedent does —
  # so a slot or role this gem predates is carried, never refused.
  def test_the_prompt_document_fixtures_parse_and_unknown_words_are_carried
    pack = contract("prompt_documents.json")
    valid = pack.fetch("valid_fixture")

    doc = api_client(valid).workspace("fixture-workspace").prompt_documents.read("character")
    assert_instance_of CybrosAgent::Api::PromptDocument, doc
    assert_equal valid.dig("prompt_document", "slot"), doc.slot
    assert_equal valid.dig("prompt_document", "role"), doc.role
    assert_equal valid.dig("prompt_document", "version"), doc.version
    assert_equal valid.dig("prompt_document", "content"), doc.content
    assert_equal (pack.fetch("basic_projection") + pack.fetch("full_projection_adds")).sort,
      CybrosAgent::Api::PromptDocument.members.map(&:to_s).sort,
      "the typed document carries exactly the presenter's projection"
    assert_includes pack.fetch("slots"), doc.slot
    assert_includes pack.fetch("roles"), doc.role
    # THE PLACED SLOTS AND THE ONE THAT IS NOT:
    # `assembly_slots` are the template's; `summarizer` is a slot of the
    # door alone — the agent profile's text for the kernel-mode compaction
    # summarizer, content-only, written through this same context.
    assert_equal pack.fetch("assembly_slots"), pack.fetch("slots") & pack.fetch("assembly_slots"),
      "every placed slot is a slot, in the door's order"
    assert_equal ["summarizer"], pack.fetch("slots") - pack.fetch("assembly_slots")
    assert_equal "agent", pack.dig("slot_anchors", "summarizer"), "the agent profile's own row"
    pack.fetch("slots").each { |slot| assert pack.fetch("slot_anchors").key?(slot), "#{slot} names its anchor" }

    listed = api_client(pack.fetch("valid_list_fixture")).profile.prompt_documents.list
    assert_equal 1, listed.length
    assert_nil listed.first.content

    written = api_client(valid).profile.prompt_documents.write("character", "x")
    assert_equal valid.dig("prompt_document", "bytesize"), written.bytesize

    unknown_slot = api_client(pack.fetch("unknown_slot_fixture")).profile.prompt_documents.read("mood")
    assert_equal "mood", unknown_slot.slot
    unknown_role = api_client(pack.fetch("unknown_role_fixture")).profile.prompt_documents.read("character")
    assert_equal "tool", unknown_role.role

    error_fixture = pack.fetch("valid_error_fixture")
    assert_equal pack.fetch("error_statuses").fetch(error_fixture.dig("body", "error", "code")),
      error_fixture.fetch("status")
  end

  # THE CLAIMANT'S EXTENSION: the pack's request rides the
  # extend door byte for byte and its answer — the claim's own shape, the
  # deadline moved, the token unrotated — parses through the real context;
  # the door's three conflicts and its 422 are the pack's.
  def test_the_extend_fixtures_ride_the_real_executor_door
    inbox = contract("executor_inbox.json")
    request = inbox.fetch("extend_request_fixture")
    fixture = inbox.fetch("extend_fixture")
    row = fixture.fetch("task")
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, fixture]])
    extended = CybrosAgent::ExecutorClient.new(base_url: "http://example.test", credential: "fixture-executor-token",
      transport: transport)
      .inbox_task(agent_loop_public_id: row.fetch("agent_loop_public_id"), task_key: row.fetch("task_key"))
      .extend(claim_token: request.fetch("claim_token"), timeout_ms: request.fetch("timeout_ms"))

    assert_equal inbox.fetch("extend_envelope").sort, request.keys.sort
    assert_equal request, transport.requests.fetch(0).fetch(:body), "the fixture rides the extension verbatim"
    assert_instance_of CybrosAgent::Api::ClaimedTask, extended
    assert_equal fixture.dig("claim", "claim_token"), extended.claim_token
    assert_equal request.fetch("claim_token"), extended.claim_token, "the token is unrotated"
    assert_equal fixture.dig("claim", "deadline_at"), extended.deadline_at
    assert_equal row.fetch("deadline_at"), extended.task.deadline_at
    assert_equal row.fetch("workspace_public_id"), extended.task.workspace_public_id
    assert_predicate extended.task, :claimed?
    assert_operator request.fetch("timeout_ms"), :<=, inbox.fetch("extend_bound_ms")
    %w[not_extendable not_claimant extension_too_long].each { |code| assert_equal 409, inbox.dig("error_statuses", code) }
    assert_equal 422, inbox.dig("error_statuses", "invalid_timeout_ms")
  end

  # THE FOUR EXTENDED ENVELOPES: a code that carries one
  # more member beside `code` and `message` reaches the caller as
  # `Api::Error#details`, exactly the members the pack publishes; a plain
  # envelope's details are empty, and every typed failure carries them.
  def test_extended_error_envelopes_reach_the_caller_as_details
    errors = contract("errors.json")
    extended = errors.fetch("extended_envelopes")
    fixture = errors.fetch("extended_fixture")
    code = fixture.dig("body", "error", "code")
    transport = CybrosAgentTest::FakeTransport.new([[fixture.fetch("status"), fixture.fetch("headers"), fixture.fetch("body")]])
    client = CybrosAgent::Client.new(base_url: "http://example.test", credential: "fixture-member-token",
      transport: transport)

    error = assert_raises(CybrosAgent::Api::Conflict) do
      client.workspace("019f0000-0000-7000-8000-000000000101").agent_loops.fetch("019f0000-0000-7000-8000-000000000601")
    end
    assert_equal code, error.code
    assert_equal extended.fetch(code), error.details.keys, "exactly the members the pack publishes"
    assert_equal fixture.dig("body", "error", "current_revision"), error.details.fetch("current_revision")
    assert_predicate error.details, :frozen?

    steps = [{ "path" => "steps[0].instructions", "code" => "instructions_raw_only" }]
    invalid = assert_raises(CybrosAgent::Api::InvalidRequest) do
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "fixture-member-token",
        transport: CybrosAgentTest::FakeTransport.new([[422, {}, { "error" => {
          "code" => "invalid_steps", "message" => "Step payload failed to compile", "steps" => steps,
        } }]]))
        .workspace("019f0000-0000-7000-8000-000000000101").agent_loops.fetch("019f0000-0000-7000-8000-000000000601")
    end
    assert_equal extended.fetch("invalid_steps"), invalid.details.keys
    assert_equal steps, invalid.details.fetch("steps")

    plain = assert_raises(CybrosAgent::Api::Unauthorized) do
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "fixture-member-token",
        transport: CybrosAgentTest::FakeTransport.new([[401, {}, errors.dig("valid_fixture", "body")]]))
        .workspace("019f0000-0000-7000-8000-000000000101").agent_loops.fetch("019f0000-0000-7000-8000-000000000601")
    end
    assert_equal({}, plain.details)
  end

  def test_unknown_api_error_code_is_carried_and_classified_by_status
    fixture = contract("errors.json").fetch("unknown_code_fixture")
    transport = CybrosAgentTest::FakeTransport.new([
      [fixture.fetch("status"), fixture.fetch("headers"), fixture.fetch("body")],
    ])
    client = CybrosAgent::Client.new(
      base_url: "http://example.test",
      credential: "fixture-member-token",
      transport: transport
    )

    error = assert_raises(CybrosAgent::Api::Conflict) { client.profile.fetch }

    assert_equal fixture.dig("body", "error", "code"), error.code
  end
end
