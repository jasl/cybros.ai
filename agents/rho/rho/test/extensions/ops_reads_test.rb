require_relative "../test_helper"
require_relative "../support/ops_harness"

# Kernel content, prompt inspection and document routes exposed by Ops.
class OpsReadsTest < Minitest::Test
  include RhoTest::OpsHarness

  # The daemon is the only thing on this machine holding a credential to
  # ask with, so a browser page served here never has to hold a member
  # token — and a terminal gets the same bytes.
  def test_the_transcript_is_proxied_with_the_prefix_and_cursor_the_caller_asked_for
    page = {
      "rounds" => [
        { "task_key" => "r3", "spine" => false, "status" => "completed", "visibility" => "visible",
          "text_preview" => "reading the file",
          "calls" => { "count" => 1, "items" => [{ "task_key" => "r3t0", "name" => "read", "status" => "completed",
                                                   "output_preview" => "class Foo" }] },
          "branches" => [] },
      ],
      "pagination" => { "next_before" => "cursor-2", "has_older" => true },
    }
    api = NexusDoubles::FakeAgentApi.new(transcript: page)
    daemon = member_ready(boot, api)

    response = request(daemon, :get,
      "/loops/transcript?public_id=al-9&prefix=r1t0&limit=5&before=cursor-1", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    body = JSON.parse(response.body).fetch("transcript")
    assert_equal %w[rounds next_before has_older], body.keys, "one density: nothing echoes a view"
    assert_equal "cursor-2", body.fetch("next_before")
    assert body.fetch("has_older")
    assert_equal page.fetch("rounds"), body.fetch("rounds"), "the thread's rows reach the page as the kernel spelled them"
    params = api.requests.find { |path, _, _| path.end_with?("/transcript") }&.last
    assert_equal({ "prefix" => "r1t0", "limit" => 5, "before" => "cursor-1" }, params)
  end

  def test_a_task_read_carries_the_question_the_arguments_and_the_output
    detail = { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "read",
               "tool_input" => { "path" => "/srv/app/x.rb" }, "output" => "class Foo", "output_preview" => "class Foo",
               "on_failure" => "halt", "visibility" => "visible",
               "result" => { "resolved" => true, "is_error" => true },
               "created_at" => "2026-09-04T00:00:00Z" }
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(task_detail: detail))

    response = request(daemon, :get, "/loops/task?public_id=al-9&task_key=r1t0",
      token: bearer(daemon))

    assert_equal "200", response.code, response.body
    row = JSON.parse(response.body).fetch("task")
    assert_equal "r1t0", row.fetch("key")
    assert_equal({ "path" => "/srv/app/x.rb" }, row.fetch("tool_input"))
    assert_equal "class Foo", row.fetch("output")
    assert_equal "class Foo", row.fetch("output_preview"), "the settled call's preview, for a reader that attached late"
    # The kernel's outcome summary rides the read: a
    # `completed, is_error` call is told apart from a write that landed.
    assert_equal({ "resolved" => true, "is_error" => true }, row.fetch("result"))
    refute row.key?("title"), "a result that sent no UI fields serves none"
    refute row.key?("metadata")
  end

  # THE BYTES READ, proxied: the daemon fetches an upload's
  # bytes on the member plane — streamed through the SDK into a spool —
  # and answers them whole as an octet stream; the kernel's 404 for an id
  # the credential may not read relays as itself; no id is malformed.
  def test_an_uploads_bytes_are_proxied_whole_and_an_unreadable_id_is_the_kernels_404
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(upload_bytes: { "up-1" => "PNG\x00BYTES".b }))

    response = request(daemon, :get, "/uploads/bytes?public_id=up-1", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal "application/octet-stream", response["content-type"]
    assert_equal "PNG\x00BYTES".b, response.body.b
    assert_equal "9", response["content-length"]

    missing = request(daemon, :get, "/uploads/bytes?public_id=up-9", token: bearer(daemon))
    assert_equal "404", missing.code
    assert_equal "not_found", JSON.parse(missing.body).dig("error", "code")

    bare = request(daemon, :get, "/uploads/bytes", token: bearer(daemon))
    assert_equal "400", bare.code
  end

  # THE NAMED REPRESENTATION READS through the same route: `kind`
  # picks the SDK's verb; the kernel's typed refusal for an upload with no
  # representation of that kind relays as itself; a kind the SDK has no
  # verb for is malformed at rho's edge and never reaches the kernel.
  def test_an_uploads_thumbnail_or_preview_is_proxied_by_kind_and_the_typed_refusal_relays
    fake = NexusDoubles::FakeAgentApi.new(upload_bytes: { "up-1" => "PNG\x00BYTES".b, "up-2" => "plain words".b },
      upload_representations: { "thumbnail" => { "up-1" => "SMALL".b }, "preview" => { "up-1" => "BIGGER".b } })
    daemon = member_ready(boot, fake)

    thumbnail = request(daemon, :get, "/uploads/bytes?public_id=up-1&kind=thumbnail", token: bearer(daemon))
    assert_equal "200", thumbnail.code, thumbnail.body
    assert_equal "SMALL".b, thumbnail.body.b
    preview = request(daemon, :get, "/uploads/bytes?public_id=up-1&kind=preview", token: bearer(daemon))
    assert_equal "BIGGER".b, preview.body.b
    whole = request(daemon, :get, "/uploads/bytes?public_id=up-1&kind=bytes", token: bearer(daemon))
    assert_equal "PNG\x00BYTES".b, whole.body.b, "`bytes` by name is the plain read"

    none = request(daemon, :get, "/uploads/bytes?public_id=up-2&kind=thumbnail", token: bearer(daemon))
    assert_equal "404", none.code
    assert_equal "representation_unavailable", JSON.parse(none.body).dig("error", "code")

    unknown = request(daemon, :get, "/uploads/bytes?public_id=up-1&kind=original", token: bearer(daemon))
    assert_equal "400", unknown.code
    assert_equal ["/agent_api/v1/uploads/up-1/thumbnail", "/agent_api/v1/uploads/up-1/preview",
                  "/agent_api/v1/uploads/up-1/bytes", "/agent_api/v1/uploads/up-2/thumbnail"],
      fake.requests.map(&:first).grep(%r{/uploads/up-}), "an unknown kind never reaches the kernel"
  end

  # The UI's two fields ride the task read through the daemon:
  # what the executor committed as `title` and `metadata`, when it did.
  def test_a_task_read_carries_the_title_and_metadata_the_executor_committed
    detail = { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "read",
               "output" => "", "structured_content" => { "lines" => 1 },
               "title" => "read x.rb", "metadata" => { "checkpoint" => "c1" },
               "on_failure" => "absorb", "visibility" => "visible",
               "created_at" => "2026-09-04T00:00:00Z" }
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(task_detail: detail))

    response = request(daemon, :get, "/loops/task?public_id=al-9&task_key=r1t0",
      token: bearer(daemon))

    assert_equal "200", response.code, response.body
    row = JSON.parse(response.body).fetch("task")
    assert_equal "read x.rb", row.fetch("title")
    assert_equal({ "checkpoint" => "c1" }, row.fetch("metadata"))
    assert_equal "", row.fetch("output"), "structure alone is the empty word, served as such"
  end

  # THE PICTURE, proxied like the transcript: the whole run as nodes, edges
  # and the Mermaid text, for a terminal to print and a page to draw.
  def test_the_graph_is_proxied_whole
    path = File.expand_path("../../../../../contracts/nexus/v1/agent_loops.json", __dir__)
    # UTF-8 BY NAME (the house rule): this machine has no LANG, so the
    # default external is US-ASCII and the fixture's mermaid separator is
    # a multibyte character.
    picture = JSON.parse(File.read(path, encoding: Encoding::UTF_8)).fetch("valid_graph_fixture")
    api = NexusDoubles::FakeAgentApi.new(graph: picture)
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/loops/graph?public_id=al-9", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    body = JSON.parse(response.body).fetch("graph")
    assert_equal picture, body
    assert api.requests.any? { |path, _, _| path.end_with?("/agent_loops/al-9/graph") }
  end

  # THE DEBUG DOOR, proxied: a round's sealed request
  # — exactly the entries and the request options, as the kernel sealed
  # them — by loop id and task key.
  def test_the_sealed_request_of_a_round_is_proxied_whole
    sealed = { "request" => {
      "entries" => [
        { "role" => "system", "parts" => [{ "type" => "text", "text" => "You can call several tools in one message." }] },
        { "role" => "user", "parts" => [{ "type" => "text", "text" => "fix it" }] },
      ],
      "request_options" => { "temperature" => 0.2, "tools" => [{ "type" => "function", "function" => { "name" => "read" } }] },
    } }
    api = NexusDoubles::FakeAgentApi.new(task_request: sealed)
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/loops/request?public_id=al-9&task_key=r1", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    body = JSON.parse(response.body).fetch("request")
    assert_equal %w[entries request_options], body.keys, "two keys, nothing derived"
    assert_equal sealed.dig("request", "entries"), body.fetch("entries")
    assert_equal sealed.dig("request", "request_options"), body.fetch("request_options")
    assert api.requests.any? { |path, _, _| path.end_with?("/agent_loops/al-9/tasks/r1/request") }
  end

  # The same verb by conversation and TURN (UUID-shaped, so `rho request`
  # tells it from a key): the turn's ACTIVE variant, read through the deck.
  def test_the_sealed_request_of_a_turn_reads_its_active_variant
    sealed = { "request" => {
      "entries" => [
        { "role" => "system", "parts" => [{ "type" => "text", "text" => "You can call several tools in one message." }] },
        { "role" => "user", "parts" => [{ "type" => "text", "text" => "fix it" }] },
      ],
      "request_options" => { "temperature" => 0.2, "tools" => [{ "type" => "function", "function" => { "name" => "read" } }] },
    } }
    deck = { "turn" => { "public_id" => "t-1", "inherited" => false },
             "variants" => [
               { "public_id" => "v-1", "source" => "inference", "status" => "completed", "active" => false },
               { "public_id" => "v-2", "source" => "inference", "status" => "completed", "active" => true },
             ] }
    api = NexusDoubles::FakeAgentApi.new(variants: deck, variant_request: sealed)
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/loops/request?public_id=c-1&turn=t-1", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal sealed.fetch("request"), JSON.parse(response.body).fetch("request")
    assert api.requests.any? { |path, _, _| path.end_with?("/conversations/c-1/turns/t-1/variants/v-2/request") },
      "the active candidate's, never the first listed"
  end

  # A key or a turn, one of the two; the kernel's `request_not_sealed` (a
  # tool row, a reply that never minted) relays as its own 404.
  def test_the_sealed_request_needs_a_key_or_a_turn_and_relays_the_kernels_refusal
    refusal = CybrosAgent::Response.new(status: 404, headers: {},
      body: { "error" => { "code" => "request_not_sealed", "message" => "This task has no sealed request" } })
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(task_request: refusal))

    assert_equal "400", request(daemon, :get, "/loops/request?public_id=al-9", token: bearer(daemon)).code
    assert_equal "400", request(daemon, :get, "/loops/request?task_key=r1", token: bearer(daemon)).code
    assert_equal "401", request(daemon, :get, "/loops/request?public_id=al-9&task_key=r1").code
    response = request(daemon, :get, "/loops/request?public_id=al-9&task_key=r1t0", token: bearer(daemon))
    assert_equal "404", response.code, response.body
    assert_equal "request_not_sealed", JSON.parse(response.body).dig("error", "code")
  end

  # THE PREVIEW ROUTE: the estimate rendered, posted
  # through the SDK under the member plane the daemon holds — `render:
  # true` always, the addressee as `to`, the values and a trial template
  # verbatim — and answered as one document a terminal prints.
  ESTIMATE = {
    "context_estimate" => {
      "input_tokens" => 812, "tokenizer_exact" => true, "catalog_input_token_limit" => 128_000,
      "advisory_input_token_limit" => 100_000, "message_count" => 2,
      "history" => { "selected" => 4, "skipped" => 12, "skipped_reason" => "budget_exceeded", "compacted" => 9 },
      "mechanism" => "assembly",
      "entries" => [{ "role" => "system", "parts" => [{ "type" => "text", "text" => "You are the room's narrator." }] },
                    { "role" => "user", "parts" => [{ "type" => "text", "text" => "first\n\nand this question" }] }],
      "storage" => { "bytes" => 158, "bound" => 1_048_576, "within_bound" => true },
      "blocks" => [
        { "block" => "slot:system_prompt", "index" => 0, "type" => "slot", "role" => "system", "state" => "selected",
          "tokens" => 6, "allocated_tokens" => 6 },
        { "block" => "history", "index" => 1, "type" => "history", "role" => "user", "state" => "selected",
          "tokens" => 3, "allocated_tokens" => 99_991 },
        { "block" => "input", "index" => 2, "type" => "input", "role" => "user", "state" => "selected",
          "tokens" => 4, "allocated_tokens" => 4 },
      ],
      "memory" => { "included" => 0, "omitted" => 0 },
      "slots" => { "system_prompt" => 4 },
    },
  }.freeze

  def test_the_prompt_preview_route_posts_the_estimate_rendered_under_the_addressee
    api = NexusDoubles::FakeAgentApi.new(context_estimate: ESTIMATE)
    daemon = member_ready(boot, api)
    template = { "blocks" => [{ "type" => "history" }, { "type" => "input" }] }

    response = request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon), body: {
      "public_id" => "c-1", "model" => "dev/mock-text", "prompt" => "and this question", "to" => "@narrator",
      "variables" => { "scene" => "a rainy night" }, "template" => template,
    })

    assert_equal "200", response.code, response.body
    preview = JSON.parse(response.body).fetch("preview")
    expected = ESTIMATE.fetch("context_estimate")
    assert_equal %w[mechanism input_tokens tokenizer_exact catalog_input_token_limit advisory_input_token_limit
                    message_count history entries storage blocks memory slots], preview.keys
    assert_equal expected.fetch("entries"), preview.fetch("entries"), "the entries verbatim"
    assert_equal expected.fetch("blocks"), preview.fetch("blocks")
    assert_equal expected.fetch("storage"), preview.fetch("storage")
    assert_equal expected.fetch("history"), preview.fetch("history")
    assert_equal({ "system_prompt" => 4 }, preview.fetch("slots"))

    posted = api.context_estimates.fetch(0)
    assert posted.fetch(:path).end_with?("/conversations/c-1/context_estimate"), posted.fetch(:path)
    body = posted.fetch(:body).fetch("context_estimate")
    assert_equal true, body.fetch("render"), "always the bytes: a preview is the estimate rendered"
    assert_equal({ "model" => "dev/mock-text" }, body.fetch("model"))
    assert_equal "and this question", body.fetch("prompt")
    assert_equal "@narrator", body.fetch("answering_user_public_id"), "`to` is the kernel's own word, passed verbatim"
    assert_equal({ "scene" => "a rainy night" }, body.fetch("variables"))
    assert_equal template, body.fetch("template")
  end

  # The words it needs, the settings' model as the fallback for a
  # conversation this daemon does not follow, and the kernel's refusal
  # relayed as itself.
  def test_the_prompt_preview_route_needs_its_words_and_relays_the_kernel
    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "prompt_template_invalid",
                           "message" => "Prompt template is outside the template grammar (after_input) at /blocks/3" } })
    api = NexusDoubles::FakeAgentApi.new(context_estimate: refusal)
    daemon = member_ready(boot, api)

    assert_equal "400", request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon),
      body: { "model" => "dev/mock-text" }).code
    assert_equal "400", request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon),
      body: { "public_id" => "c-1" }).code, "no model named and none in the settings"
    assert_equal "400", request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon),
      body: { "public_id" => "c-1", "model" => "dev/mock-text", "variables" => "scene" }).code
    assert_equal "401", request(daemon, :post, "/conversations/prompt_preview",
      body: { "public_id" => "c-1", "model" => "dev/mock-text" }).code
    response = request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon),
      body: { "public_id" => "c-1", "model" => "dev/mock-text" })
    assert_equal "422", response.code, response.body
    assert_equal "prompt_template_invalid", JSON.parse(response.body).dig("error", "code")
    assert_empty api.context_estimates.reject { |posted| posted.fetch(:body).dig("context_estimate", "render") },
      "nothing reached the kernel without the bytes asked for"
  end

  def test_the_prompt_preview_route_falls_back_to_the_settings_model
    api = NexusDoubles::FakeAgentApi.new(context_estimate: ESTIMATE)
    daemon = member_ready(boot(config: agent_mode("default_model" => "dev/mock-text")), api)

    response = request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon),
      body: { "public_id" => "c-1", "prompt" => "x" })

    assert_equal "200", response.code, response.body
    assert_equal({ "model" => "dev/mock-text" }, api.context_estimates.fetch(0).fetch(:body).dig("context_estimate", "model"))
  end

  # A preview names an existing conversation, whose next send is `say`, so
  # it compiles on the model `say` would send: the row's own ahead of the
  # settings' `default_model`, and on an attached row that remembers none
  # and no settings model, the addressed turn's off the loop projection.
  def test_the_prompt_preview_route_takes_the_model_say_would_send_on
    api = NexusDoubles::FakeAgentApi.new(context_estimate: ESTIMATE)
    daemon = member_ready(boot(config: agent_mode("default_model" => "dev/mock-text")), api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", turn: "t-1", loop: "al-1",
      model: "openrouter/opened-with")

    response = request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon),
      body: { "public_id" => "c-1", "prompt" => "x" })
    assert_equal "200", response.code, response.body
    assert_equal({ "model" => "openrouter/opened-with" },
      api.context_estimates.fetch(0).fetch(:body).dig("context_estimate", "model"), "the row's model beats the settings'")

    turn = { "status" => "running", "public_id" => "t-2", "conversation_public_id" => "c-2",
             "model" => { "model" => "openrouter/from-turn" } }
    api = NexusDoubles::FakeAgentApi.new(context_estimate: ESTIMATE,
      trace: NexusDoubles::RUNNING_TRACE.merge("turn" => turn))
    bare = member_ready(boot(root: File.join(@root, "bare")), api)
    host_store(bare)
      .remember(Rho::Host::Conversation.new(public_id: "c-2"), workspace: "ws-1", turn: "t-2", loop: "al-9")

    response = request(bare, :post, "/conversations/prompt_preview", token: bearer(bare),
      body: { "public_id" => "c-2", "prompt" => "x" })
    assert_equal "200", response.code, response.body
    assert_equal({ "model" => "openrouter/from-turn" },
      api.context_estimates.fetch(0).fetch(:body).dig("context_estimate", "model"),
      "no row model and no default_model: the addressed turn's")
  end

  # `rho prompt show`: the profile's own slots through the member plane —
  # listed, or one read whole; the kernel's `prompt_slot_unavailable`
  # relays as itself.
  def test_the_prompt_documents_route_lists_and_reads_the_profiles_slots
    rows = [{ "slot" => "system_prompt", "role" => "system", "bytesize" => 19, "version" => 3,
              "written_at" => "2026-09-08T00:00:00Z", "content" => "Prefer small diffs." }]
    api = NexusDoubles::FakeAgentApi.new(prompt_documents: rows)
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/prompt/documents", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    listed = JSON.parse(response.body).fetch("prompt_documents")
    assert_equal [rows.first.except("content")], listed, "a listing carries no text"

    response = request(daemon, :get, "/prompt/documents?slot=system_prompt", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal rows.first, JSON.parse(response.body).fetch("prompt_document")

    response = request(daemon, :get, "/prompt/documents?slot=persona", token: bearer(daemon))
    assert_equal "422", response.code, response.body
    assert_equal "prompt_slot_unavailable", JSON.parse(response.body).dig("error", "code")
    assert_equal "401", request(daemon, :get, "/prompt/documents").code
  end

  def test_the_reads_need_their_parameters_and_an_adopted_workspace
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(transcript: { "rounds" => [] }))

    assert_equal "400", request(daemon, :get, "/loops/transcript", token: bearer(daemon)).code
    assert_equal "400",
      request(daemon, :get, "/loops/task?public_id=al-9", token: bearer(daemon)).code
    assert_equal "400", request(daemon, :get, "/loops/graph", token: bearer(daemon)).code
    assert_equal "401", request(daemon, :get, "/loops/transcript?public_id=al-9").code
    assert_equal "401", request(daemon, :get, "/loops/graph?public_id=al-9").code
  end

  # `rho skills`' ROW HALF: the two rungs through the
  # two memory doors that own them — the person's `user/` at the profile
  # door, the workspace rung at the adopted workspace's OWN door (no conversation picked, none followed) — the
  # kernel's skill words relayed as the 422s they are.
  def test_the_skill_routes_reach_the_two_rungs_through_their_doors
    api = NexusDoubles::FakeAgentApi.new
    api.stock_memory("profile", "user/notes.md", "n")
    api.stock_memory("profile", "user/skills/review-checklist", "# Review\n", description: "Review: how I do it.")
    api.stock_memory("workspace", "workspace/notes.md", "w")
    api.stock_memory("c-1", "user/skills/review-checklist", "# Review\n", description: "a conversation door's row, never read here")
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/skills/push", token: bearer(daemon),
      body: { scope: "workspace", name: "commit-style", description: "How commits are written.", content: "# Commits\n",
              expected_public_id: nil, expected_lock_version: nil })
    assert_equal "201", response.code, response.body
    written = JSON.parse(response.body).fetch("memory")
    assert_equal ["workspace/skills/commit-style", "How commits are written."], written.values_at("path", "description")
    assert_equal({ "path" => "workspace/skills/commit-style", "content" => "# Commits\n",
                   "description" => "How commits are written.", "expected_public_id" => nil,
                   "expected_lock_version" => nil }, api.memory_writes.fetch(0),
      "the description rides the door's write beside the path and the content")

    response = request(daemon, :get, "/skills", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    skills = JSON.parse(response.body).fetch("skills")
    assert_equal ["review-checklist"], skills.fetch("user").map { |row| row.fetch("name") }
    assert_equal "Review: how I do it.", skills.fetch("user").first.fetch("description")
    assert_equal ["commit-style"], skills.fetch("workspace").map { |row| row.fetch("name") }, "workspace/skills/ only"
    refute skills.key?("conversation"), "the workspace rung is the room's own door: no conversation names it"
    assert api.requests.any? { |path, _, _| path.match?(%r{/workspaces/[^/]+/memory\z}) },
      "the workspace door, not a conversation's"
    assert_equal [], skills.fetch("project"), "agent mode loads no runner tool: its runner address announces no document"

    response = request(daemon, :get, "/skills/show?scope=workspace&name=commit-style", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal "# Commits\n", JSON.parse(response.body).dig("memory", "content")

    response = request(daemon, :post, "/skills/push", token: bearer(daemon),
      body: { scope: "user", name: "nope", content: "x", expected_public_id: nil, expected_lock_version: nil })
    assert_equal "422", response.code, response.body
    assert_equal "skill_description_required", JSON.parse(response.body).dig("error", "code")

    response = request(daemon, :post, "/skills/rm", token: bearer(daemon),
      body: { scope: "workspace", name: "commit-style", expected_public_id: written.fetch("public_id"),
              expected_lock_version: written.fetch("lock_version") })
    assert_equal "200", response.code, response.body
    assert_equal "workspace/skills/commit-style", JSON.parse(response.body).dig("deleted", "path")
    response = request(daemon, :get, "/skills/show?scope=workspace&name=commit-style", token: bearer(daemon))
    assert_equal "404", response.code, response.body

    assert_equal "400", request(daemon, :get, "/skills/show?scope=project&name=x", token: bearer(daemon)).code
    assert_equal "401", request(daemon, :get, "/skills").code
  end

  def test_skill_mutations_preserve_the_callers_observation_and_relay_conflicts
    api = NexusDoubles::FakeAgentApi.new
    api.stock_memory("workspace", "workspace/skills/review", "old", description: "Review a change.")
    daemon = member_ready(boot, api)
    read = request(daemon, :get, "/skills/show?scope=workspace&name=review", token: bearer(daemon))
    observed = JSON.parse(read.body).fetch("memory")
    condition = { expected_public_id: observed.fetch("public_id"), expected_lock_version: observed.fetch("lock_version") }
    body = { scope: "workspace", name: "review", description: "Review a change.", content: "new", **condition }
    response = request(daemon, :post, "/skills/push", token: bearer(daemon), body: body)
    assert_equal "201", response.code, response.body
    assert_equal condition.values, api.memory_writes.last.values_at("expected_public_id", "expected_lock_version")

    ["/skills/push", "/skills/rm"].each do |path|
      response = request(daemon, :post, path, token: bearer(daemon), body: body)
      assert_equal "409", response.code, response.body
      assert_equal "stale_object", JSON.parse(response.body).dig("error", "code")
    end
    assert_equal 1, api.requests.count { |path, _, _| path.end_with?("/memory/show") },
      "mutations must not fetch a newer version behind the caller's back"
    read = request(daemon, :get, "/skills/show?scope=workspace&name=review", token: bearer(daemon))
    assert_equal "new", JSON.parse(read.body).dig("memory", "content")
    listed = JSON.parse(request(daemon, :get, "/skills", token: bearer(daemon)).body).dig("skills", "workspace").first
    assert_equal [observed.fetch("public_id"), observed.fetch("lock_version") + 1], listed.values_at("public_id", "lock_version")
  end

  def test_skill_push_rejects_non_text_content_before_reaching_the_kernel
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/skills/push", token: bearer(daemon),
      body: { scope: "user", name: "review", description: "Review a change.", content: { text: "x" },
              expected_public_id: nil, expected_lock_version: nil })

    assert_equal "400", response.code, response.body
    assert_equal "content must be a string", JSON.parse(response.body).dig("error", "message")
    assert_empty api.memory_writes
  end

  def test_skill_mutations_require_both_condition_fields_before_reaching_the_kernel
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    body = { scope: "user", name: "review", description: "Review a change.", content: "x" }

    ["/skills/push", "/skills/rm"].each do |path|
      [body, body.merge(expected_public_id: nil)].each do |input|
        response = request(daemon, :post, path, token: bearer(daemon), body: input)
        assert_equal "400", response.code, response.body
        assert_equal "parameter_missing", JSON.parse(response.body).dig("error", "code")
      end
    end
    assert_empty api.memory_writes
  end

  # The PROJECT section: what this daemon's runner
  # announces under `documents` — the root's skills as the Coding extension
  # scans them, the same reader `announce_tools` uses — beside the rows.
  def test_the_project_section_is_the_roots_announced_documents
    root = File.join(@root, "src")
    dir = File.join(root, ".agents", "skills", "deploy-notes")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), "---\nname: deploy-notes\ndescription: How this project is deployed.\n---\n# Deploy\n")
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot(extensions: [Rho::Extensions::Ops, Rho::Runner::Extensions::Coding],
      config: Rho::Config.from_hash("mode" => "full", "tools_root" => root)), api)

    response = request(daemon, :get, "/skills", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    skills = JSON.parse(response.body).fetch("skills")
    assert_equal [{ "name" => "deploy-notes", "description" => "How this project is deployed." }], skills.fetch("project")
    assert_equal skills.fetch("project"),
      Rho::LoopRequest.documents(registry: daemon.context.registry.serving(:runner),
        environment: Rho::Runner::Environment.local(root: root)),
      "the section is the announcement's own bytes"
  end
end
