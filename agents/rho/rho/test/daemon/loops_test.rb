require "support/daemon_loop_helpers"

class DaemonLoopsTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers


  # THE RUNNER A NEW HOST STARTS ON: the body's own, else the
  # settings' `runner` — read FRESH from the file each time, because `rho
  # runners use` writes it from the CLI process and the daemon writes
  # settings never (correction (f)) — else this machine's own
  # runner row; none names none.
  def test_do_carries_the_runner_selection_on_the_create_reading_the_settings_file_fresh
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("0199-set"), NexusDoubles.remote_runner("0199-named")])
    daemon = member_ready(boot, api)
    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal [{ "conversation" => {} }], api.conversation_creates, "no setting, no own row: unnamed, and the kernel infers none"

    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "runner_executor_public_id" => "0199-named" })
    assert_equal "0199-named", api.conversation_creates.last.dig("conversation", "runner_executor_public_id")

    File.write(daemon.home.settings_path, JSON.generate("runner" => "0199-set"))
    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "0199-set", api.conversation_creates.last.dig("conversation", "runner_executor_public_id"),
      "the settings' runner, written after the boot and read fresh"
    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "runner_executor_public_id" => "0199-named" })
    assert_equal "0199-named", api.conversation_creates.last.dig("conversation", "runner_executor_public_id"),
      "the body's wins over the settings'"

    File.write(daemon.home.settings_path, JSON.generate({}))
    own = member_ready(boot(root: File.join(@root, "own")), NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE),
      identity: RUNNER_IDENTITY)
    open(own, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "0199-runner", own.wire.api_transport.conversation_creates.last.dig("conversation", "runner_executor_public_id"),
      "this machine's own runner row"
  end

  # THE RESTRICTED CONVERSATION: `access_default`
  # on the body rides the create as the carrier's default, with the
  # STEWARD's `full` entry beside it — read off this home's own row in the
  # principals listing, rho's entry and never the kernel's — and the 201
  # answer carries the default so the terminal prints it. No default on
  # the body sends no carrier; a word the kernel does not know is 400.
  def test_do_restricted_opens_with_default_none_and_the_stewards_full_entry
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    api.stock_principals([
      { "public_id" => "steward-1", "handle" => "steward", "kind" => "human", "display_name" => "Steward",
        "agent_identifier" => nil, "steward_public_id" => nil },
      { "public_id" => IDENTITY.user_public_id, "handle" => "rho", "kind" => "agent", "display_name" => "rho",
        "agent_identifier" => "rho", "steward_public_id" => "steward-1" },
    ])
    daemon = member_ready(boot, api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "access_default" => "none" })
    assert_equal "201", code, answer.inspect
    assert_equal({ "default" => "none", "entries" => [{ "user_public_id" => "steward-1", "level" => "full" }] },
      api.conversation_creates.last.dig("conversation", "access"))
    assert_equal "none", answer["access"], "the answer names the default the verb asked for"

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "201", code
    refute api.conversation_creates.last.fetch("conversation").key?("access"), "no default asked: the kernel's own full"
    refute answer.key?("access")

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "access_default" => "owner" })
    assert_equal "400", code
    assert_equal "malformed_body", answer.dig("error", "code")
  end

  # `rho do --agent IDENT`: a human names
  # the answerer as `@handle` or a public id, resolved through the
  # principals listing and sent as `answering_user_public_id` at the
  # create door; unknown is the door word `principal_unknown` naming the
  # handles the listing knows. A FOREIGN answerer's first turn carries no
  # `tool_names`, no `approval_mode` and no lead — those are rho's own
  # declaration's words and the kernel judges them against the ADDRESSEE's
  # — and the row remembers whom it is answered by, so `rho say`
  # on it sends the bare words too. Naming rho itself changes nothing.
  def test_do_agent_names_the_answerer_and_a_foreign_one_gets_the_bare_words
    api = kernel_api
    api.stock_principals([
      { "public_id" => "steward-1", "handle" => "steward", "kind" => "human", "display_name" => "Steward",
        "agent_identifier" => nil, "steward_public_id" => nil },
      { "public_id" => IDENTITY.user_public_id, "handle" => "rho", "kind" => "agent", "display_name" => "rho",
        "agent_identifier" => "rho.1", "steward_public_id" => "steward-1" },
      { "public_id" => "peer-1", "handle" => "lark", "kind" => "agent", "display_name" => "Lark",
        "agent_identifier" => "rho.2", "steward_public_id" => "steward-1" },
    ])
    daemon = member_ready(boot(config: tiered), api)

    code, answer = open(daemon, { "prompt" => "review it", "model" => "openrouter/x", "agent" => "@lark" })
    assert_equal "201", code, answer.inspect
    assert_equal "peer-1", api.conversation_creates.last.dig("conversation", "answering_user_public_id")
    assert_equal({ "public_id" => "peer-1", "handle" => "lark" }, answer["answered_by"])
    input = api.conversation_inputs.last.fetch("input")
    assert_equal({ "kind" => "direct_reply", "text" => "review it", "delivery_mode" => "queue",
                   "model" => { "model" => "openrouter/x" } }, input,
      "a foreign answerer gets the words alone: no tool_names, no approval_mode, no lead")
    assert_equal "peer-1", store.find(answer.dig("conversation", "public_id")).answerer

    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: answer.dig("conversation", "public_id"), text: "and the tests" })
    assert_equal "200", said.code, said.body
    refute api.conversation_inputs.last.fetch("input").key?("tool_names"), "the row's answerer is foreign: bare words"
    refute api.conversation_inputs.last.fetch("input").key?("inline")

    code, answer = open(daemon, { "prompt" => "review it", "model" => "openrouter/x", "agent" => "peer-1" })
    assert_equal "201", code, answer.inspect
    assert_equal "peer-1", api.conversation_creates.last.dig("conversation", "answering_user_public_id"),
      "a public id resolves too"

    code, answer = open(daemon, { "prompt" => "review it", "model" => "openrouter/x", "agent" => "@rho", "compose" => false })
    assert_equal "201", code, answer.inspect
    assert_equal IDENTITY.user_public_id, api.conversation_creates.last.dig("conversation", "answering_user_public_id")
    assert_equal names_without_compose, api.conversation_inputs.last.dig("input", "tool_names"),
      "rho itself named: its own tier as ever"
    assert_nil store.find(answer.dig("conversation", "public_id")).answerer, "own is the row's nil"

    code, answer = open(daemon, { "prompt" => "review it", "model" => "openrouter/x", "agent" => "@nobody" })
    assert_equal "404", code
    assert_equal "principal_unknown", answer.dig("error", "code")
    assert_match(/@nobody/, answer.dig("error", "message"))
    assert_match(/@lark/, answer.dig("error", "message"), "the refusal names the handles the listing knows")
    assert_match(/@rho/, answer.dig("error", "message"))

    code, answer = open(daemon, { "prompt" => "review it", "model" => "openrouter/x", "agent" => "" })
    assert_equal "400", code
  end

  # `rho say ID "…" --to IDENT`:
  # WHO ANSWERS THIS TURN, per call — resolved through the principals
  # listing like `--agent` and sent as the door's `answering_user_public_id`
  # (the SDK's `to:`). The bare decision is keyed on the ADDRESSEE, never
  # on the row: a `--to` naming another profile sends the words alone (no
  # `tool_names`, no `approval_mode`, no lead — those are this machine's
  # declaration's, judged against the addressee's), even on a row rho
  # itself answers; a `--to` naming rho itself on a FOREIGN row sends
  # rho's own tier again, and the lead the bare open withheld — as every
  # plain turn carries one (the lead rides every turn).
  # The answer names the addressee so the terminal can print it; unknown
  # is `principal_unknown`; a loop host has one answerer and refuses the
  # word by name before the kernel would (`not_admitted`).
  def test_say_to_names_the_turns_answerer_and_the_bare_words_follow_the_addressee_not_the_row
    api = kernel_api
    api.stock_principals([
      { "public_id" => "steward-1", "handle" => "steward", "kind" => "human", "display_name" => "Steward",
        "agent_identifier" => nil, "steward_public_id" => nil },
      { "public_id" => IDENTITY.user_public_id, "handle" => "rho", "kind" => "agent", "display_name" => "rho",
        "agent_identifier" => "rho.1", "steward_public_id" => "steward-1" },
      { "public_id" => "peer-1", "handle" => "lark", "kind" => "agent", "display_name" => "Lark",
        "agent_identifier" => "rho.2", "steward_public_id" => "steward-1" },
    ])
    daemon = member_ready(boot(config: tiered), api)

    # A row rho answers: `--to @lark` is the bare words, addressed.
    code, answer = open(daemon, { "prompt" => "review it", "model" => "openrouter/x", "compose" => false })
    assert_equal "201", code, answer.inspect
    own = answer.dig("conversation", "public_id")
    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: own, text: "and you, lark?", to: "@lark" })
    assert_equal "200", said.code, said.body
    input = api.conversation_inputs.last.fetch("input")
    assert_equal({ "kind" => "direct_reply", "text" => "and you, lark?", "delivery_mode" => "steer",
                   "model" => { "model" => "openrouter/x" }, "answering_user_public_id" => "peer-1" }, input,
      "a foreign addressee gets the words alone, addressed: no tool_names, no approval_mode, no lead")
    assert_equal({ "public_id" => "peer-1", "handle" => "lark" }, JSON.parse(said.body)["addressed_to"],
      "the answer names the addressee for the terminal")
    assert_nil store.find(own).answerer, "`--to` is the turn's, never the row's: the row still says rho answers"

    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: own, text: "back to you", to: "@rho" })
    assert_equal "200", said.code, said.body
    input = api.conversation_inputs.last.fetch("input")
    assert_equal names_without_compose, input["tool_names"], "rho itself named on its own row: the tier's names as ever"
    assert_equal IDENTITY.user_public_id, input["answering_user_public_id"]
    assert_equal({ "public_id" => IDENTITY.user_public_id, "handle" => "rho" }, JSON.parse(said.body)["addressed_to"])

    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: own, text: "plain" })
    assert_equal "200", said.code, said.body
    refute api.conversation_inputs.last.fetch("input").key?("answering_user_public_id"),
      "no --to sends no addressee: the kernel's default (the running answerer for a steer, else the conversation's)"

    # A FOREIGN row (`--agent @lark`): a `--to @rho` on it is rho's own turn
    # — its tier's names ride, and so does the lead the bare open withheld.
    code, answer = open(daemon, { "prompt" => "review it", "model" => "openrouter/x", "agent" => "@lark", "compose" => false })
    assert_equal "201", code, answer.inspect
    foreign = answer.dig("conversation", "public_id")
    refute api.conversation_inputs.last.fetch("input").key?("tool_names")
    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: foreign, text: "rho, your view?", to: "@rho" })
    assert_equal "200", said.code, said.body
    input = api.conversation_inputs.last.fetch("input")
    assert_equal names_without_compose, input["tool_names"], "rho named on a foreign row: rho's own tier"
    assert_equal IDENTITY.user_public_id, input["answering_user_public_id"]
    assert_equal %w[developer lead], [input.dig("inline", 0, "role"), input.dig("inline", 0, "position")],
      "rho's own turn on a foreign row carries the lead the bare open withheld"
    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: foreign, text: "and lark again" })
    assert_equal "200", said.code, said.body
    input = api.conversation_inputs.last.fetch("input")
    refute input.key?("tool_names"), "unnamed on a foreign row: the row's remembered answerer, bare"
    refute input.key?("answering_user_public_id")

    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: own, text: "hi", to: "@nobody" })
    assert_equal "404", said.code
    assert_equal "principal_unknown", JSON.parse(said.body).dig("error", "code")
    assert_match(/@lark/, JSON.parse(said.body).dig("error", "message"))

    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: own, text: "hi", to: " " })
    assert_equal "400", said.code, "an empty address is malformed, never the default"

    store.remember(loop_host("al-solo"), workspace: "ws-1")
    said = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "al-solo", text: "hi", to: "@lark" })
    assert_equal "400", said.code, said.body
    assert_match(/one answerer/, JSON.parse(said.body).dig("error", "message"), "a loop host has one answerer")
  end

  # `rho conversation participants` over ONE route: a PUT whose body
  # names no change answers the carrier as the kernel holds it (the SDK's
  # fetch); `add`, `rm` and `default` re-cut the WHOLE set and PUT it back
  # — the read-modify-write is the daemon's, the kernel's door a whole
  # replacement. The conversation need not be followed: a person re-cuts
  # any conversation of the adopted workspace.
  # `GET /providers` (the provider admission floor): the lanes
  # off the member plane, the kernel's `unavailable_until` passed through
  # as sent — a string while a floor stands, null when clear.
  def test_the_providers_route_lists_the_lanes_with_the_kernels_clock
    lane = { "id" => "openrouter", "credentials" => "api_key", "enabled" => true, "lock_version" => 3,
             "configured" => true, "material_kind" => "api_key", "reauthorization_required" => false,
             "models" => 12, "unavailable_until" => nil }
    floored = lane.merge("id" => "dev", "credentials" => "none", "material_kind" => nil, "models" => 2,
                         "unavailable_until" => "2026-09-16T09:00:00Z")
    api = NexusDoubles::FakeAgentApi.new(model_providers: [lane, floored])
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/providers", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    rows = JSON.parse(response.body).fetch("providers")
    assert_equal %w[openrouter dev], rows.map { |row| row.fetch("id") }
    assert_nil rows.fetch(0).fetch("unavailable_until")
    assert_equal "2026-09-16T09:00:00Z", rows.fetch(1).fetch("unavailable_until")
    assert_equal({ "id" => "dev", "credentials" => "none", "enabled" => true, "configured" => true,
                   "reauthorization_required" => false, "models" => 2,
                   "unavailable_until" => "2026-09-16T09:00:00Z" }, rows.fetch(1))
  end

  # `GET /adaptations` (rho-dev's facts line): a model without its lane
  # segment is refused as a missing one is — before the pack or the kernel
  # is read, never a 500 from the SDK's ArgumentError.
  def test_the_adaptations_route_refuses_a_model_without_its_lane_segment
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new)

    response = request(daemon, :get, "/adaptations?model=mock-text", token: bearer(daemon))

    assert_equal "400", response.code, response.body
    assert_equal({ "code" => "malformed_body", "message" => "model is required, as provider/reference" },
      JSON.parse(response.body).fetch("error").slice("code", "message"))
  end

  def test_the_adaptations_route_reports_no_facts_when_a_model_is_not_in_the_available_listing
    api = NexusDoubles::FakeAgentApi.new(models: [])
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/adaptations?model=dev/mock-text", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal({ "known" => false }, JSON.parse(response.body).fetch("facts"))
    path, credential, params = api.requests.find { |entry| entry.first == "/agent_api/v1/models" }
    assert_equal "/agent_api/v1/models", path
    assert_equal NexusDoubles::MEMBER_TOKEN, credential
    assert_nil params
  end

  def test_the_access_route_lists_and_re_cuts_the_whole_carrier_over_the_sdk
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    api.stock_principals([{ "public_id" => "peer-1", "handle" => "peer", "kind" => "agent", "display_name" => "Peer",
                            "agent_identifier" => "peer", "steward_public_id" => "steward-1" }])
    daemon = member_ready(boot, api)
    access = ->(body) {
      response = request(daemon, :put, "/conversations/access", token: bearer(daemon), body: body)
      [response.code, JSON.parse(response.body)]
    }

    code, answer = access.call({ "public_id" => "c-7" })
    assert_equal "200", code, answer.inspect
    assert_equal({ "conversation" => { "public_id" => "c-7" }, "access" => { "default" => "full", "entries" => [] } }, answer)
    assert_nil api.access_of("c-7"), "a listing writes nothing"

    code, answer = access.call({ "public_id" => "c-7", "change" => { "op" => "add", "principal" => "peer-1", "level" => "read" } })
    assert_equal "200", code, answer.inspect
    assert_equal [{ "user_public_id" => "peer-1", "handle" => "peer", "kind" => "agent", "display_name" => "Peer",
                    "level" => "read" }], answer.dig("access", "entries")
    assert_equal({ "default" => "full", "entries" => [{ "user_public_id" => "peer-1", "level" => "read" }] }, api.access_of("c-7"))

    code, answer = access.call({ "public_id" => "c-7", "change" => { "op" => "default", "level" => "none" } })
    assert_equal "200", code
    assert_equal "none", answer.dig("access", "default")
    assert_equal({ "default" => "none", "entries" => [{ "user_public_id" => "peer-1", "level" => "read" }] }, api.access_of("c-7"),
      "a default change keeps the entries")

    # THE HANDLE SPELLING: `@peer` names the same principal;
    # the re-cut sends the handle as given and keeps the kept rows by id.
    code, answer = access.call({ "public_id" => "c-7", "change" => { "op" => "add", "principal" => "@peer", "level" => "full" } })
    assert_equal "200", code, answer.inspect
    assert_equal [{ "handle" => "peer", "level" => "full" }], api.access_of("c-7").fetch("entries"), "add re-levels, by either spelling"
    assert_equal [["peer-1", "peer", "full"]],
      answer.dig("access", "entries").map { |row| row.values_at("user_public_id", "handle", "level") }

    code, answer = access.call({ "public_id" => "c-7", "change" => { "op" => "rm", "principal" => "@peer" } })
    assert_equal "200", code
    assert_equal({ "default" => "none", "entries" => [] }, api.access_of("c-7"))
    assert_empty answer.dig("access", "entries")

    code, = access.call({ "public_id" => "c-7", "change" => { "op" => "add", "principal" => "peer-1", "level" => "read" } })
    assert_equal "200", code
    code, = access.call({ "public_id" => "c-7", "change" => { "op" => "rm", "principal" => "peer-1" } })
    assert_equal "200", code
    assert_equal({ "default" => "none", "entries" => [] }, api.access_of("c-7"), "rm by public id too")

    code, answer = access.call({ "public_id" => "c-7", "change" => { "op" => "zap" } })
    assert_equal "400", code
    assert_equal "malformed_body", answer.dig("error", "code")
    code, = access.call({})
    assert_equal "400", code
  end

  # THE APPROVAL KNOB ON THE DOOR: `approval_mode` rides the
  # reply input the core posts — the kernel's own field, like `model` and
  # `tool_names` — admitted in the kernel's vocabulary (`bypass` is
  # rank-equal and lawful; the flag simply does not offer it) and refused
  # as malformed otherwise. The kernel's own refusal — `not_tightening`,
  # reachable for rho only when its profile holds no declaration — relays
  # as the 422 sentence `rho do` prints; the conversation was created
  # BEFORE the input, so a refused input leaves an empty remembered
  # conversation, as any input refusal does today.
  def test_do_with_an_approval_mode_posts_it_on_the_reply_input_and_relays_the_kernels_refusal
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)

    code, answer = open(daemon, { "prompt" => "push it", "model" => "dev/mock-text", "approval_mode" => "ask" })
    assert_equal "201", code, answer.inspect
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal "ask", input.fetch("approval_mode"), "the turn's tightening rides THIS input"
    assert_equal({ "model" => "dev/mock-text" }, input.fetch("model"))

    code, answer = open(daemon, { "prompt" => "push it", "model" => "dev/mock-text" })
    assert_equal "201", code, answer.inspect
    refute api.conversation_inputs.fetch(1).fetch("input").key?("approval_mode"), "no knob, no field: the profile's word"

    code, answer = open(daemon, { "prompt" => "push it", "model" => "dev/mock-text", "approval_mode" => "telepathy" })
    assert_equal "400", code, answer.inspect
    assert_equal "malformed_body", answer.dig("error", "code")
    assert_match(/approval_mode must be bypass, ask or rules/, answer.dig("error", "message"))
    assert_equal 2, api.conversation_inputs.length, "nothing reached the kernel"

    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed",
                           "message" => "Approval mode only tightens the declaring profile's approval_mode" } })
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_input: refusal)
    refused = boot(root: File.join(@root, "refused"))
    daemon = member_ready(refused, api)
    code, answer = open(daemon, { "prompt" => "push it", "model" => "dev/mock-text", "approval_mode" => "ask" })
    assert_equal "422", code, answer.inspect
    assert_equal "validation_failed", answer.dig("error", "code")
    assert_match(/only tightens/, answer.dig("error", "message"), "the kernel's sentence, relayed")
    assert_equal 1, api.conversation_creates.length, "the conversation was created before the input was refused"
    remembered = host_store(refused).rows.map(&:host_public_id)
    assert_equal %w[c-1], remembered, "and remembered, empty — today's residue for any refused input"
  end

  # PICTURES BESIDE THE WORDS: the verb posts PATHS; the
  # daemon — the one holder of the member plane — reads each, stages it
  # through the kernel's ingest as rho's own user, and names the ids on
  # the input as `attachments` beside the text; the answer carries the
  # descriptors the kernel sniffed for the terminal's `attached:` lines.
  def test_say_with_attachments_stages_them_on_the_member_plane_and_binds_the_ids
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    # The queued words below await a loop the fake never mints:
    # the bound is the injected clock's, spent in poll steps, not real seconds.
    now = Time.utc(2026, 9, 6)
    daemon = member_ready(boot(clock: -> { now += Rho::Daemon::Loops::MATERIALIZATION_POLL },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    _code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    conversation = answer.dig("conversation", "public_id")
    picture = picture_file("diagram.png")

    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: conversation, text: "what is this?", delivery_mode: "queue", attachments: [picture] })
    assert_equal "200", said.code, said.body
    assert_equal %w[diagram.png], api.uploads.map { |upload| upload.fetch(:filename) }
    assert_equal PNG, api.uploads.first.fetch(:bytes), "the daemon read the bytes and streamed them"
    input = api.conversation_inputs.last.fetch("input")
    assert_equal %w[up-1], input.fetch("attachments"), "the staged ids ride the input beside the words"
    assert_equal ["what is this?", "queue"], [input.fetch("text"), input.fetch("delivery_mode")]
    document = JSON.parse(said.body)
    assert_equal [{ "filename" => "diagram.png", "content_type" => "image/png", "byte_size" => PNG.bytesize }],
      document.fetch("attachments"), "the descriptors as the kernel answered them"

    # A steer takes none (the kernel's word, before a byte is staged).
    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: conversation, text: "now", attachments: [picture] })
    assert_equal "422", said.code
    assert_equal "attachments_not_steerable", JSON.parse(said.body).dig("error", "code")
    assert_equal 1, api.uploads.length, "nothing staged for a refused steer"

    # A path that is not a file is refused by name, and nothing is staged.
    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: conversation, text: "and this", delivery_mode: "queue",
              attachments: [File.join(@root, "missing.png")] })
    assert_equal "422", said.code
    assert_equal "attachment_unreadable", JSON.parse(said.body).dig("error", "code")
    assert_equal 1, api.uploads.length
    assert_equal 2, api.conversation_inputs.length, "no input posted for either refusal"

    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: conversation, text: "plain", delivery_mode: "queue", attachments: "diagram.png" })
    assert_equal "400", said.code, "a list of paths, or nothing"
  end

  # `rho do --attach`: the first message is the one that most often
  # carries a picture; the open stages it and the reply input names it.
  def test_do_with_attachments_stages_them_and_the_reply_input_names_the_ids
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)

    code, answer = open(daemon, { "prompt" => "what is this?", "model" => "dev/mock-text",
                                  "attachments" => [picture_file("shot.png")] })

    assert_equal "201", code, answer.inspect
    assert_equal %w[shot.png], api.uploads.map { |upload| upload.fetch(:filename) }
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal %w[up-1], input.fetch("attachments")
    assert_equal "queue", input.fetch("delivery_mode")
    assert_equal [{ "filename" => "shot.png", "content_type" => "image/png", "byte_size" => PNG.bytesize }],
      answer.fetch("attachments")

    code, answer = open(daemon, { "prompt" => "plain", "model" => "dev/mock-text" })
    assert_equal "201", code
    refute answer.key?("attachments"), "no pictures, no line"
    refute api.conversation_inputs.last.fetch("input").key?("attachments")
  end

  def test_do_opens_a_conversation_posts_the_reply_and_answers_the_three_ids
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }, sleeper: ->(_) { }), api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "idempotency_key" => "k-a" })

    assert_equal "201", code, answer.inspect
    assert_equal({ "public_id" => "c-1" }, answer.fetch("conversation"))
    assert_equal({ "public_id" => "t-1" }, answer.fetch("turn"))
    assert_equal({ "public_id" => "al-1" }, answer.fetch("loop"))
    refute answer.key?("tools"), "the declaration is the profile's, not the turn's"
    assert_equal({ "on" => true, "source" => "row default" }, answer.fetch("compose"), "the tier, and why: the default row's word")
    assert_equal({ "row" => "default", "source" => "gem" }, answer.fetch("adaptations"), "the row line after compose")
    assert_nil answer["until"]
    wait_for { daemon.lineage.run("c-1")&.snapshot&.loop == "al-1" }
    assert_equal %w[al-1], followed(daemon).fetch(0).fetch("loops")

    assert_equal [{ "conversation" => {} }], api.conversation_creates
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal ["direct_reply", "fix it", "queue"], [input.fetch("kind"), input.fetch("text"), input.fetch("delivery_mode")]
    assert_equal({ "model" => "dev/mock-text" }, input.fetch("model"))
    lead, *rest = input.fetch("inline")
    assert_empty rest, "ONE inline entry"
    # DEVELOPER-ROLE: behind history, outside the stable
    # prefix — what changes per turn and per runner; the guideline is the
    # profile's `system_prompt` slot, written at boot, and never rides here.
    assert_equal %w[developer lead], [lead.fetch("role"), lead.fetch("position")]
    assert lead.fetch("text").start_with?("Relative paths resolve against"), "the environment block leads"
    assert lead.fetch("text").end_with?("start_process, never `&`."), "the last tool line closes it"
    refute_includes lead.fetch("text"), Rho::LoopRequest::GUIDELINE
    assert_equal ["c-1"], daemon.lineage.runs.map(&:public_id), "the conversation is followed"

    row = store.rows.fetch(0)
    assert_equal %w[conversation c-1 t-1 al-1 dev/mock-text], [row.host_type, row.host_public_id, row.turn, row.loop, row.model]
    assert_equal({}, row.notes)
  end

  # THE PROMPTLESS OPEN (a session IS a conversation, opened with no turn): no `prompt` on the body creates
  # the conversation on its create-door fields, follows it and remembers
  # it — no input, no turn, no loop, no model check, no tier — and the 201
  # names the conversation and the runner slot alone. The row remembers
  # the model the flag named (the first `say` rides it), and the first
  # `say` renders the lead as every plain turn does (the lead rides every turn). A field only a turn carries —
  # the instructions, the tightening, the check — is refused
  # by name: nothing is dropped silently.
  def test_do_without_a_prompt_opens_the_conversation_follows_it_and_posts_no_turn
    # The page is the test's to release (`page`), as the side case does:
    # nothing has materialized on a conversation with no turn, and the
    # fake's unconditional page would write a turn into the row.
    page = Queue.new
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: page)
    now = Time.utc(2026, 9, 17)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil },
      clock: -> { page.empty? ? now : (now += Rho::Daemon::Loops::MATERIALIZATION_POLL) },
      sleeper: ->(_seconds) { sleep 0.001 }), api, identity: RUNNER_IDENTITY)

    code, answer = open(daemon, { "model" => "dev/mock-text", "working_directory" => @root })

    assert_equal "201", code, answer.inspect
    assert_equal({ "public_id" => "c-1" }, answer.fetch("conversation"))
    assert_equal({ "executor_public_id" => "0199-runner" }, answer.fetch("runner"), "this machine's own runner, its id alone")
    %w[turn loop pending compose adaptations until].each { |key| refute answer.key?(key), "#{key} rides a turn; none was opened" }
    assert_equal [{ "conversation" => { "runner_executor_public_id" => "0199-runner" } }], api.conversation_creates
    assert_empty api.conversation_inputs, "no prompt, no input"
    assert_equal ["c-1"], daemon.lineage.runs.map(&:public_id), "the conversation is followed"
    row = store.rows.fetch(0)
    assert_equal ["conversation", "c-1", nil, nil, "dev/mock-text", "0199-runner"],
      [row.host_type, row.host_public_id, row.turn, row.loop, row.model, row.runner]

    saying = Thread.new do
      request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "first words", delivery_mode: "queue" })
    end
    wait_for { api.conversation_inputs.any? }
    page << true
    response = saying.value
    assert_equal "200", response.code, response.body
    assert_equal [{ "public_id" => "t-1" }, { "public_id" => "al-1" }], JSON.parse(response.body).values_at("turn", "loop"),
      "the first say answers the turn it opened"
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal({ "model" => "dev/mock-text" }, input.fetch("model"), "the flag's model, remembered on the row")
    lead, *rest = input.fetch("inline")
    assert_empty rest, "ONE inline entry"
    assert_equal %w[developer lead], [lead.fetch("role"), lead.fetch("position")]
    assert lead.fetch("text").start_with?("Relative paths resolve against"), "the first say renders the lead"

    bare = member_ready(boot(root: File.join(@root, "bare")), NexusDoubles::FakeAgentApi.new)
    code, answer = open(bare, {})
    assert_equal "201", code, "no model either: nothing to check before a turn exists"
    assert_nil answer.fetch("runner"), "none bound"
    assert_nil host_store(bare).rows.fetch(0).model

    { "instructions" => "be brief", "approval_mode" => "ask",
      "until" => { "command" => "true" } }.each do |key, value|
      code, answer = open(bare, { key => value })
      assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")], "#{key} rides a turn"
      assert_includes answer.dig("error", "message"), key
    end
  end

  # THE COMPOSE SWITCH, MECHANISM (B): the declaration stays the profile's whole set, and the
  # turn's subset rides the INPUT as `tool_names` — every declared flat
  # name but compose when the tier is off, no field at all when on. The
  # 201 says which tier and its source — the model's local row — and the
  # row it ran under (`adaptations`); the store row remembers the tier for `say`.
  def test_do_off_compose_names_the_turns_tools_on_the_input_and_says_so
    api = kernel_api
    mock_row
    daemon = member_ready(boot(config: tiered("default_model" => "dev/mock-text")), api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })

    assert_equal "201", code, answer.inspect
    assert_equal({ "on" => false, "source" => "row mock-off" }, answer.fetch("compose"))
    assert_equal({ "row" => "mock-off", "source" => "local" }, answer.fetch("adaptations"),
      "the row line after compose: the model's row and its source (a boot row line only when the two differ)")
    refute answer.key?("tools"), "the line names the tier, never the tool list"
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal names_without_compose, input.fetch("tool_names")
    assert_equal({ "model" => "dev/mock-text" }, input.fetch("model"), "the tools ride beside the model")
    assert_equal false, store.rows.fetch(0).compose
    assert_empty api.configuration_declarations, "nothing re-declares the profile per turn"
  end

  # THE BOOT ROW IS THE UNIVERSE AND THE VIEW: the profile declares the `default_model`'s row — a local row for
  # the mock spelling task as `Agent` under `[claude]`, its recut rendered
  # against the template the fake SERVED — and every turn sees the whole
  # declaration: no per-model style narrowing rides the input. A `--model`
  # on another reference runs under the boot's spellings (the 201 says
  # so: `boot_row`), and reads ITS OWN row for the hints and the compose
  # rung — here the default row, so compose stays on and no hint rides.
  def test_do_the_boot_row_is_the_universe_and_another_models_turn_runs_under_its_spellings
    pack = CybrosAgent::ModelAdaptations.load
    anchor = pack.presets.preset("claude").aliases.first.dig("recut", "anchor")
    served = NexusDoubles::KERNEL_CATALOG.map do |row|
      row.fetch("canonical_name") == "nexus.graph.task" ? row.merge("template" => "The task verb.\n\n#{anchor}") : row
    end
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: served)
    mock_row("mock", tool_style: ["claude"], lead_hints: [{ "id" => "k6", "text" => "Do not wait for a detached call." }])
    daemon = member_ready(boot(config: tiered("default_model" => "dev/mock-text")), api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "201", code, answer.inspect
    assert_equal({ "row" => "mock", "source" => "local" }, answer.fetch("adaptations"))
    assert_equal({ "on" => false, "source" => "row mock" }, answer.fetch("compose"))
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal names_without_compose - ["task"] + ["Agent"], input.fetch("tool_names"),
      "the compose narrowing over the boot row's universe: Agent declared, plain task never was"
    assert input.dig("inline", 0, "text").end_with?("start_process, never `&`.\n\nDo not wait for a detached call."),
      "the row's hint rides the developer lead after the tool lines"
    # The recut itself is the configuration test's (`adopted` declares;
    # `member_ready` does not) — here the tier's names prove the universe.

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/other-model" })
    assert_equal "201", code
    assert_equal({ "row" => "default", "source" => "gem", "boot_row" => "mock" }, answer.fetch("adaptations"),
      "another model's row: the spellings are the boot's, said on the answer")
    assert_equal({ "on" => true, "source" => "row default" }, answer.fetch("compose"))
    second = api.conversation_inputs.fetch(1).fetch("input")
    refute second.key?("tool_names"), "compose on under the default row: the whole universe, Agent included"
    assert second.dig("inline", 0, "text").end_with?("start_process, never `&`."), "no hint on the default row"
    assert_empty api.configuration_declarations, "nothing re-declares the profile per turn"
    assert_equal({ "row" => "mock", "source" => "local" },
      daemon.loops.adaptations.facts.transform_keys(&:to_s), "the boot row is the default model's")
  end

  # The flag beats the table; `on` runs the whole declaration and names
  # nothing; a flag that is not true or false is refused.
  def test_do_the_flag_wins_the_tier_back_and_on_names_no_subset
    api = kernel_api
    mock_row
    daemon = member_ready(boot(config: tiered), api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "compose" => true })

    assert_equal "201", code, answer.inspect
    assert_equal({ "on" => true, "source" => "flag" }, answer.fetch("compose"))
    refute api.conversation_inputs.fetch(0).fetch("input").key?("tool_names"), "on runs the whole declaration"
    assert_equal true, store.rows.fetch(0).compose

    code, answer = open(daemon, { "prompt" => "p", "model" => "dev/mock-text", "compose" => "yes" })
    assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")]
    assert_match(/compose must be true or false/, answer.dig("error", "message"))
  end

  # A pending turn still says its tier: the input went out with it.
  def test_a_pending_turn_still_answers_the_tier
    now = Time.utc(2026, 9, 6)
    api = NexusDoubles::FakeAgentApi.new(conversation_events: [], tools: NexusDoubles::KERNEL_CATALOG)
    daemon = member_ready(boot(config: tiered("compose" => "off"),
      clock: -> { now += Rho::Daemon::Loops::MATERIALIZATION_WAIT }), api)

    code, answer = open(daemon, { "prompt" => "p", "model" => "dev/mock-text" })

    assert_equal "201", code, answer.inspect
    assert answer.fetch("pending")
    assert_equal({ "on" => false, "source" => "settings" }, answer.fetch("compose"))
    assert_equal names_without_compose, api.conversation_inputs.fetch(0).dig("input", "tool_names")
  end

  # The person's own words replace the tool guidance and the environment
  # still leads (the operator did not ask to lose it).
  def test_stated_instructions_replace_the_guidance_in_the_lead
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)

    code, = open(daemon, { "prompt" => "p", "model" => "dev/mock-text", "instructions" => "Be brief." })

    assert_equal "201", code
    lead = api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text")
    assert lead.start_with?("Relative paths resolve against")
    assert lead.end_with?("Be brief.")
    refute_includes lead, "bash:"
  end

  # THE MODEL HAS ONE HOME: the flag, else the settings' default, else a
  # refusal here — the CLI cannot read the daemon's settings.
  def test_the_model_falls_back_to_the_settings_default_and_is_refused_when_neither_names_one
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(config: Rho::Config.from_hash("default_model" => "openrouter/default")), api)

    code, = open(daemon, { "prompt" => "p" })
    assert_equal "201", code
    assert_equal({ "model" => "openrouter/default" }, api.conversation_inputs.fetch(0).dig("input", "model"))
    assert_equal "openrouter/default", store.rows.fetch(0).model

    bare = member_ready(boot(root: File.join(@root, "bare")), NexusDoubles::FakeAgentApi.new)
    code, answer = open(bare, { "prompt" => "p" })
    assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")]
    assert_match(/model is required/, answer.dig("error", "message"))
    # No prompt is the PROMPTLESS open, never a refusal:
    # the model is checked when a turn is opened, and none is here.
    code, answer = open(bare, { "model" => "m/x" })
    assert_equal "201", code, answer.inspect
    refute answer.key?("turn")
  end

  # Materialization is the kernel's job (DrainJob): a feed that never names
  # the loop within the bound answers `pending` rather than holding the
  # terminal — the input is queued and `rho watch` follows it.
  def test_a_turn_that_does_not_materialize_within_the_bound_answers_pending
    now = Time.utc(2026, 9, 6)
    api = NexusDoubles::FakeAgentApi.new(conversation_events: [])
    daemon = member_ready(boot(clock: -> { now += Rho::Daemon::Loops::MATERIALIZATION_WAIT }), api)

    code, answer = open(daemon, { "prompt" => "p", "model" => "dev/mock-text" })

    assert_equal "201", code, answer.inspect
    assert_equal({ "public_id" => "c-1" }, answer.fetch("conversation"))
    assert answer.fetch("pending")
    refute answer.key?("loop")
    assert_equal 1, api.conversation_inputs.length, "the input was posted; only the wait gave up"
    row = store.rows.fetch(0)
    assert_nil row.loop
    assert_equal "dev/mock-text", row.model
  end

  # A BLOCKED INPUT IS A REFUSAL, NOT A SLOW KERNEL: the drain marks the
  # input `blocked` (an unknown model, a refused selection) and narrates
  # `input_blocked` on the feed the follower already reads; the author
  # answers 422 with the kernel's reason WORD the moment the block lands
  # — before the loop check, before the deadline — never the 30 s bound.
  # The property pinned is the wait itself: the clock never reaches the
  # bound and the request returns in real seconds, not tens of them.
  def test_an_input_the_kernel_blocks_answers_a_refusal_without_waiting_the_bound
    start = Time.utc(2026, 9, 6)
    now = start
    events = [
      { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => "input_blocked",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-06T00:00:00Z",
        "payload" => { "input_public_id" => "cin-1", "queue_position" => 0, "blocked_reason" => "unknown_model" } },
    ]
    api = NexusDoubles::FakeAgentApi.new(conversation_events: -> { api.conversation_inputs.empty? ? [] : events })
    daemon = member_ready(boot(clock: -> { now += Rho::Daemon::Loops::MATERIALIZATION_POLL }), api)

    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    code, answer = open(daemon, { "prompt" => "p", "model" => "dev/no-such-model" })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

    assert_equal "422", code, answer.inspect
    assert_equal "input_blocked", answer.dig("error", "code")
    assert_match(/unknown_model/, answer.dig("error", "message"))
    assert_match(/open a new turn/, answer.dig("error", "message"), "the sentence names the way back")
    assert_equal({ "public_id" => "c-1" }, answer.dig("error", "conversation"))
    assert_equal 1, api.conversation_inputs.length, "the input was posted; the kernel blocked it"
    assert_operator now - start, :<, Rho::Daemon::Loops::MATERIALIZATION_WAIT, "the clock never reached the bound"
    assert_operator elapsed, :<, 5, "the terminal was not held for the bound (#{elapsed.round(1)} s)"
    refute_nil store.find("c-1"), "the conversation stands; the parked input is repairable through the API"
  end

  # `loop_held` rides the same item type with no state write — the drain
  # re-narrates it per settle while a loop needs attention — and is not a
  # block: alone on the feed it still answers `pending` at the bound.
  def test_a_loop_held_narration_is_not_a_block_and_still_answers_pending_at_the_bound
    now = Time.utc(2026, 9, 6)
    events = [
      { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => "input_blocked",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-06T00:00:00Z",
        "payload" => { "input_public_id" => "cin-1", "queue_position" => 0, "blocked_reason" => "loop_held" } },
    ]
    api = NexusDoubles::FakeAgentApi.new(conversation_events: -> { api.conversation_inputs.empty? ? [] : events })
    daemon = member_ready(boot(clock: -> { now += Rho::Daemon::Loops::MATERIALIZATION_WAIT }), api)

    code, answer = open(daemon, { "prompt" => "p", "model" => "dev/mock-text" })

    assert_equal "201", code, answer.inspect
    assert answer.fetch("pending")
    refute answer.key?("error")
  end
end
