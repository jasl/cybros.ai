require "test_helper"

# THE CONVERSATION'S ENVIRONMENT DOOR: one
# GET and one POST on `/conversations/environment` — the record read (the
# memo refreshed), the bind under ABSENT-means-keep and null-clears — and
# `GET /environments`, the live table, host mode only. Every code the
# table names; the relay to a runner elsewhere when the row's runner is
# not this machine's own.
class EnvironmentRoutesTest < Minitest::Test
  include RhoTest::DaemonHarness

  # Host policy shares this scoped Store; this suite asserts the environment
  # record's writes and lifetime independently of that policy.
  def environment_entries(api, public_id)
    api.store_entries_of(public_id).select { |row| row.fetch("namespace") == "rho.environment" }
  end

  def store = host_store

  def conversation_host(public_id) = Rho::Host::Conversation.new(public_id: public_id)

  def api(**options)
    NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, **options)
  end

  def ready(api, config: agent_mode)
    member_ready(boot(config: config), api, identity: RUNNER_IDENTITY)
  end

  def get_environment(daemon, public_id)
    response = request(daemon, :get, "/conversations/environment?public_id=#{public_id}", token: bearer(daemon))
    [response.code, JSON.parse(response.body)]
  end

  def bind(daemon, body)
    response = request(daemon, :post, "/conversations/environment", token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end

  def project(name)
    File.join(@root, name).tap { |path| FileUtils.mkdir_p(path) }
  end

  # THE RECORD, READ AND WRITTEN: a followed conversation with no
  # record answers the default; a bind creates the row —
  # `rho.environment`/`binding`, the value `{root, directories, anchor}`
  # exactly, `lock_version 0` — and the read answers it with its version
  # and stamp; `--also` moves the version to 1; an absent field keeps,
  # `[]` clears the directories, a null root clears the record.
  def test_the_door_reads_binds_keeps_and_clears_the_conversations_record
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    src = project("src")
    docs = project("docs")

    code, answer = get_environment(daemon, "c-1")
    assert_equal "200", code, answer.inspect
    assert_equal({ "root" => daemon.context.tool_env.root, "directories" => [], "source" => "default", "resolved" => true },
      answer.fetch("environment").slice("root", "directories", "source", "resolved"))

    code, answer = bind(daemon, { public_id: "c-1", root: src })
    assert_equal "200", code, answer.inspect
    environment = answer.fetch("environment")
    assert_equal [src, [], "c-1", "conversation", 0, true], environment.values_at("root", "directories", "anchor", "source", "lock_version", "resolved")
    assert_nil environment.fetch("relayed"), "this machine's own runner: nothing relayed"
    rows = environment_entries(api, "c-1")
    assert_equal 1, rows.length
    assert_equal ["rho.environment", "binding", { "root" => src, "directories" => [], "anchor" => "c-1" }, 0],
      rows.fetch(0).values_at("namespace", "key", "value", "lock_version")

    code, answer = bind(daemon, { public_id: "c-1", directories: [docs] })
    assert_equal "200", code, answer.inspect
    assert_equal [src, [docs], 1], answer.fetch("environment").values_at("root", "directories", "lock_version"), "root kept"
    assert_equal({ "root" => src, "directories" => [docs], "anchor" => "c-1" }, environment_entries(api, "c-1").fetch(0).fetch("value"))

    code, answer = bind(daemon, { public_id: "c-1" })
    assert_equal "200", code
    assert_equal 1, answer.fetch("environment").fetch("lock_version"), "nothing named: nothing written"

    code, answer = bind(daemon, { public_id: "c-1", directories: [] })
    assert_equal [src, [], 2], answer.fetch("environment").values_at("root", "directories", "lock_version"), "[] clears the directories"

    code, answer = get_environment(daemon, "c-1")
    assert_equal "200", code
    assert_equal [src, 2, "conversation"], answer.fetch("environment").values_at("root", "lock_version", "source")
    assert_kind_of String, answer.fetch("environment").fetch("updated_at")

    code, answer = bind(daemon, { public_id: "c-1", root: nil })
    assert_equal "200", code, answer.inspect
    assert_equal "default", answer.fetch("environment").fetch("source"), "a null root clears the record"
    assert_empty environment_entries(api, "c-1")
  end

  # THE CODES: no id is malformed; an unfollowed id is 404; a root
  # that is no directory 422 `not_a_directory`; a root or a directory
  # under a protected root 422 `protected_root` — refused at the door,
  # nothing written; a record another writer keeps moving is 409
  # `environment_contended`; the kernel's own bound crosses as itself.
  def test_the_door_refuses_by_code_and_writes_nothing_on_a_refusal
    api = api(store_entry_update: CybrosAgent::Response.new(status: 409, headers: {},
      body: { "error" => { "code" => "stale_object", "message" => "moved" } }))
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    src = project("src")

    assert_equal "400", bind(daemon, { root: src }).first
    assert_equal "400", get_environment(daemon, "").first
    code, answer = bind(daemon, { public_id: "c-9", root: src })
    assert_equal ["404", "host_not_followed"], [code, answer.dig("error", "code")]
    assert_equal ["404", "host_not_followed"], get_environment(daemon, "c-9").then { |c, a| [c, a.dig("error", "code")] }

    code, answer = bind(daemon, { public_id: "c-1", root: File.join(@root, "nope") })
    assert_equal ["422", "not_a_directory"], [code, answer.dig("error", "code")]
    code, answer = bind(daemon, { public_id: "c-1", root: Rho.root })
    assert_equal ["422", "protected_root"], [code, answer.dig("error", "code")]
    code, answer = bind(daemon, { public_id: "c-1", root: src, directories: [File.join(daemon.home.root, "settings.json")] })
    assert_equal ["422", "protected_root"], [code, answer.dig("error", "code")]
    code, answer = bind(daemon, { public_id: "c-1", root: src, directories: "src" })
    assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")]
    assert_empty environment_entries(api, "c-1"), "nothing written on a refusal"

    code, answer = bind(daemon, { public_id: "c-1", directories: [src] })
    assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")], "nothing to keep: a root is required"

    assert_equal "200", bind(daemon, { public_id: "c-1", root: src }).first
    code, answer = bind(daemon, { public_id: "c-1", root: project("elsewhere") })
    assert_equal ["409", "environment_contended"], [code, answer.dig("error", "code")]
    assert_equal 2, api.store_entry_updates.length, "one retry, then the refusal — never a force"
  end

  # THE LIVE TABLE: `GET /environments` lists every followed
  # conversation's memo row; a runner-mode daemon serves none of it.
  def test_environments_lists_the_followed_rows_records_in_host_mode_alone
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    store.remember(conversation_host("c-2"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    src = project("src")
    bind(daemon, { public_id: "c-1", root: src })
    get_environment(daemon, "c-2")

    response = request(daemon, :get, "/environments", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal [{ "conversation" => "c-1", "root" => src, "directories" => [], "anchor" => "c-1",
                    "source" => "conversation", "relayed" => nil, "fs" => nil, "mcp" => [] }], JSON.parse(response.body).fetch("environments")
    assert_equal "401", request(daemon, :get, "/environments").code

    runner = boot(root: File.join(@root, "runner"), config: runner_mode, extensions: [Rho::Extensions::Environment])
    refused = request(runner, :get, "/environments", token: bearer(runner))
    assert_equal "409", refused.code
    assert_equal "member_plane_unavailable", JSON.parse(refused.body).dig("error", "code")
    assert_equal "409", request(runner, :get, "/conversations/environment?public_id=c-1", token: bearer(runner)).code,
      "a runner-mode rho reads no store: no member plane"
  end

  # A ROW BOUND TO A RUNNER ELSEWHERE: the bind writes the record,
  # then relays `environment_bind` to that runner as a request loop on its
  # announced park — the conversation id on the input — and the answer
  # says what the runner knows; the same tuple bound again relays nothing.
  def test_a_bind_on_a_remote_runner_row_relays_the_record_after_the_write
    api = api(
      executors: [NexusDoubles.remote_runner("0199-h", root: "/srv/elsewhere", booted_at: "2026-09-17T06:00:00Z")],
      task_detail: { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "environment_bind",
                     "output" => "bound", "result" => { "is_error" => false },
                     "structured_content" => { "applied" => true, "resolved" => true, "booted_at" => "2026-09-17T06:00:00Z" },
                     "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-17T00:00:00Z" }
    )
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-h")
    src = project("src")

    code, answer = bind(daemon, { public_id: "c-1", root: src })

    assert_equal "200", code, answer.inspect
    assert_equal({ "runner" => "0199-h", "state" => "confirmed", "booted_at" => "2026-09-17T06:00:00Z", "resolved" => true },
      answer.fetch("environment").fetch("relayed"))
    assert_equal 1, environment_entries(api, "c-1").length, "the record first"
    assert_equal [{ "name" => "environment_bind", "key" => "relay",
                    "input" => { "root" => src, "directories" => [], "anchor" => "c-1", "conversation_public_id" => "c-1" } }],
      api.loop_creates.map { |body| body.dig("agent_loop", "steps", 0, "tool") }
    assert_equal "0199-h", api.loop_creates.fetch(0).dig("agent_loop", "runner_executor_public_id")
    rules = api.loop_creates.fetch(0).dig("agent_loop", "approval_rules")
    assert rules.all? { |rule| rule["origin"] == "author" }, "the runner's own rules judge it on the path"

    code, = bind(daemon, { public_id: "c-1", root: src })
    assert_equal "200", code
    assert_equal 1, api.loop_creates.length, "the same tuple on the same boot: nothing relayed"
    assert_match(/event=environment\.relayed .*conversation=c-1 runner=0199-h/, File.read(daemon.home.log_path, encoding: Encoding::UTF_8))
  end

  # THE DOOR'S `fs:` MEMBER: `{url,
  # token, read, write, client}` registers the surface's port under the
  # record's ANCHOR — ABSENT keeps, `null` clears; the read answers `fs:
  # {client, read, write}` (never the token or the URL) and the live
  # table's row carries the same; the record is untouched by a port
  # registration (no store write). A conversation with no record has no
  # root set for a port to route on: 422 `environment_unbound`.
  def test_fs_registers_the_port_under_the_anchor_keeps_when_absent_and_clears_on_null
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    src = project("src")
    assert_equal "200", bind(daemon, { public_id: "c-1", root: src }).first
    fs = { url: "http://127.0.0.1:4321", token: "bearer-1", read: true, write: false, client: "zed" }

    code, answer = bind(daemon, { public_id: "c-1", fs: fs })
    assert_equal "200", code, answer.inspect
    environment = answer.fetch("environment")
    assert_equal({ "client" => "zed", "read" => true, "write" => false }, environment.fetch("fs"))
    refute_includes answer.to_s, "bearer-1"
    refute_includes answer.to_s, "4321"
    assert_equal 0, environment.fetch("lock_version"), "a port registration writes nothing to the store"
    assert_equal 0, api.store_entry_updates.length
    assert daemon.context.environments.port_live?("c-1")
    assert_equal({ client: "zed", read: true, write: false }, daemon.context.environments.port_for("c-1").describe)

    code, answer = get_environment(daemon, "c-1")
    assert_equal "200", code
    assert_equal({ "client" => "zed", "read" => true, "write" => false }, answer.fetch("environment").fetch("fs"))
    rows = JSON.parse(request(daemon, :get, "/environments", token: bearer(daemon)).body).fetch("environments")
    assert_equal({ "client" => "zed", "read" => true, "write" => false }, rows.fetch(0).fetch("fs"))

    code, answer = bind(daemon, { public_id: "c-1", directories: [project("docs")] })
    assert_equal "200", code
    assert_equal({ "client" => "zed", "read" => true, "write" => false }, answer.fetch("environment").fetch("fs"), "absent keeps")

    code, answer = bind(daemon, { public_id: "c-1", fs: fs.merge(write: true, client: "harbor") })
    assert_equal({ "client" => "harbor", "read" => true, "write" => true }, answer.fetch("environment").fetch("fs"), "replaced")

    code, answer = bind(daemon, { public_id: "c-1", fs: nil })
    assert_equal "200", code, answer.inspect
    assert_nil answer.fetch("environment").fetch("fs")
    refute daemon.context.environments.port_live?("c-1")
    assert_nil JSON.parse(request(daemon, :get, "/environments", token: bearer(daemon)).body).fetch("environments").fetch(0).fetch("fs")
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_match(/event=fs_port\.dropped .*anchor=c-1 reason=cleared/, log)
    refute_includes log, "bearer-1", "the token never reaches the log"

    store.remember(conversation_host("c-2"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    code, answer = bind(daemon, { public_id: "c-2", fs: fs })
    assert_equal ["422", "environment_unbound"], [code, answer.dig("error", "code")], answer.inspect
    refute daemon.context.environments.port_live?("c-2"), "no root set: nothing to route on"
    assert_nil get_environment(daemon, "c-2").last.fetch("environment").fetch("fs")
  end

  # THE PORT'S CODES: a URL that is not loopback http, a missing token, a
  # flag that is not a boolean, a body that is not an object — each 400
  # `malformed_body` with nothing registered; a row whose runner is not
  # this machine's own is 409 `runner_elsewhere` (the port is a loopback
  # endpoint of this daemon; a runner elsewhere cannot reach it).
  def test_fs_is_refused_by_code_and_nothing_is_registered_on_a_refusal
    api = api(executors: [NexusDoubles.remote_runner("0199-h", root: "/srv/elsewhere", booted_at: "2026-09-17T06:00:00Z")])
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    store.remember(conversation_host("c-2"), workspace: "ws-1", model: "m/x", runner: "0199-h")
    good = { url: "http://127.0.0.1:4321", token: "bearer-1", read: true, write: true, client: "zed" }
    assert_equal "200", bind(daemon, { public_id: "c-1", root: project("src") }).first

    [good.merge(url: "http://example.com:4321"), good.merge(url: "https://127.0.0.1:4321"), good.merge(url: "127.0.0.1:4321"),
     good.merge(token: ""), good.except(:token), good.merge(read: "yes"), good.except(:client), "zed"].each do |fs|
      code, answer = bind(daemon, { public_id: "c-1", fs: fs })
      assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")], fs.inspect
      refute daemon.context.environments.port_live?("c-1"), "nothing registered on #{fs.inspect}"
    end
    [good, good.merge(url: "http://localhost:4321"), good.merge(url: "http://[::1]:4321")].each do |fs|
      assert_equal "200", bind(daemon, { public_id: "c-1", fs: fs }).first, fs.inspect
    end

    code, answer = bind(daemon, { public_id: "c-2", fs: good })
    assert_equal ["409", "runner_elsewhere"], [code, answer.dig("error", "code")]
    refute daemon.context.environments.port_live?("c-2")
  end

  # ---- the door's `mcp:` member ----

  def servers_extension
    @closes = File.join(@root, "closes.txt")
    RhoTest::ConversationServers.extension(@root, closes: @closes)
  end

  def closed = File.exist?(@closes) ? File.read(@closes).split("\n") : []

  def declared_names(api, index = -1)
    api.configuration_declarations.fetch(index).dig("configuration", "tool_definitions").map { |e| e.dig("function", "name") }
  end

  # THE EDITOR'S SERVERS: `mcp: [...]` (the ACP list as received) binds
  # them under the record's ANCHOR and the read answers `mcp: [{name,
  # state, fault, transport}]` — never an env value; ABSENT keeps; an
  # equal list is a no-op (no close, no second declaration); a moved
  # list replaces the set (the old one closed) and `[]` closes it; the
  # union is declared once per set change with the names; the live table's
  # row carries the same rows; a secret in `env` reaches neither the answer
  # nor the log.
  def test_mcp_binds_the_editors_servers_under_the_anchor_keeps_when_absent_and_closes_on_the_empty_list
    api = api()
    daemon = ready(api, config: agent_mode("extension_paths" => [servers_extension]))
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    src = project("src")
    assert_equal "200", bind(daemon, { public_id: "c-1", root: src }).first
    declared_before = api.configuration_declarations.length
    fx = RhoTest::ConversationServers.stdio("fx")

    code, answer = bind(daemon, { public_id: "c-1", mcp: [fx] })
    assert_equal "200", code, answer.inspect
    environment = answer.fetch("environment")
    assert_equal [{ "name" => "fx", "state" => "connected", "fault" => nil, "transport" => "stdio" }], environment.fetch("mcp")
    refute_includes answer.to_s, "hunter2"
    assert_equal 0, environment.fetch("lock_version"), "a server bind writes nothing to the store"
    assert_equal %w[mcp__fx__lookup mcp__fx__paths], daemon.context.environments.servers.names_for("c-1")
    assert_equal declared_before + 1, api.configuration_declarations.length, "the union declared once for the set"
    assert_includes declared_names(api), "mcp__fx__lookup"
    assert_includes declared_names(api), "todo_write", "this machine's own entries stay in the union (agent mode: the agent's own)"

    code, answer = get_environment(daemon, "c-1")
    assert_equal "200", code
    assert_equal [{ "name" => "fx", "state" => "connected", "fault" => nil, "transport" => "stdio" }], answer.fetch("environment").fetch("mcp")
    rows = JSON.parse(request(daemon, :get, "/environments", token: bearer(daemon)).body).fetch("environments")
    assert_equal [{ "name" => "fx", "state" => "connected", "fault" => nil, "transport" => "stdio" }], rows.fetch(0).fetch("mcp")

    code, answer = bind(daemon, { public_id: "c-1", directories: [project("docs")] })
    assert_equal "200", code
    assert_equal ["fx"], answer.fetch("environment").fetch("mcp").map { |row| row.fetch("name") }, "absent keeps"

    code, answer = bind(daemon, { public_id: "c-1", mcp: [fx.merge("env" => [{ "name" => "FX_TOKEN", "value" => "rotated" }])] })
    assert_equal "200", code
    assert_empty closed, "an equal list (a value moved, no key): the held set stands"
    assert_equal declared_before + 1, api.configuration_declarations.length, "and nothing is declared again"

    code, answer = bind(daemon, { public_id: "c-1", mcp: [fx, RhoTest::ConversationServers.http("hx")] })
    assert_equal "200", code, answer.inspect
    assert_equal [%w[fx connected stdio], %w[hx connected http]],
      answer.fetch("environment").fetch("mcp").map { |row| row.values_at("name", "state", "transport") }
    assert_equal ["c-1"], closed, "a moved list closed the held set first"
    assert_equal declared_before + 2, api.configuration_declarations.length
    assert_includes declared_names(api), "mcp__hx__lookup"

    code, answer = bind(daemon, { public_id: "c-1", mcp: [] })
    assert_equal "200", code, answer.inspect
    assert_empty answer.fetch("environment").fetch("mcp")
    assert_equal %w[c-1 c-1], closed
    assert_empty daemon.context.environments.servers.names
    assert_equal declared_before + 3, api.configuration_declarations.length
    refute_includes declared_names(api), "mcp__fx__lookup"
    assert_empty JSON.parse(request(daemon, :get, "/environments", token: bearer(daemon)).body).fetch("environments").fetch(0).fetch("mcp")

    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_match(/event=mcp_servers\.closed .*anchor=c-1 reason=replaced/, log)
    assert_match(/event=mcp_servers\.closed .*anchor=c-1 reason=cleared/, log)
    refute_includes log, "hunter2", "the env value never reaches the log"
    refute_includes log, "rotated"
  end

  # THE CODES: a body that is not a list of objects is 400 `malformed_body`
  # at the door; an entry the registrar refuses is its sentence as 400; a
  # daemon nobody registered a registrar on is 422 `mcp_unavailable`; a
  # conversation with no record has no anchor to key a set on: 422
  # `environment_unbound`. A row whose runner is elsewhere still lands:
  # the servers run on the agent slot, which is here.
  def test_mcp_is_refused_by_code_and_lands_whatever_the_rows_runner
    api = api(executors: [NexusDoubles.remote_runner("0199-h", root: "/srv/elsewhere", booted_at: "2026-09-17T06:00:00Z")])
    daemon = ready(api, config: agent_mode("extension_paths" => [servers_extension]))
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    store.remember(conversation_host("c-2"), workspace: "ws-1", model: "m/x", runner: "0199-h")
    store.remember(conversation_host("c-3"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    assert_equal "200", bind(daemon, { public_id: "c-1", root: project("src") }).first
    fx = RhoTest::ConversationServers.stdio("fx")

    ["fx", { "name" => "fx" }, [1], ["fx"], nil].each do |mcp|
      code, answer = bind(daemon, { public_id: "c-1", mcp: mcp })
      assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")], mcp.inspect
      assert_empty daemon.context.environments.servers.names, "nothing bound on #{mcp.inspect}"
    end
    code, answer = bind(daemon, { public_id: "c-1", mcp: [{ "command" => "fx-server" }] })
    assert_equal ["400", "malformed_body", "a server entry needs a name"], [code, answer.dig("error", "code"), answer.dig("error", "message")]

    # A refused list over a HELD set: the held set was closed before the
    # registrar was asked, so the anchor holds nothing
    # and the union is declared again without its names.
    assert_equal "200", bind(daemon, { public_id: "c-1", mcp: [fx] }).first
    declared = api.configuration_declarations.length
    assert_includes declared_names(api), "mcp__fx__lookup"
    code, answer = bind(daemon, { public_id: "c-1", mcp: [{ "command" => "fx-server" }] })
    assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")]
    assert_equal ["c-1"], closed, "the held set went first"
    assert_empty daemon.context.environments.servers.names
    assert_equal declared + 1, api.configuration_declarations.length, "the union lost the dropped set's names"
    refute_includes declared_names(api), "mcp__fx__lookup"

    code, answer = bind(daemon, { public_id: "c-3", mcp: [fx] })
    assert_equal ["422", "environment_unbound"], [code, answer.dig("error", "code")], answer.inspect
    assert_empty daemon.context.environments.servers.names

    code, answer = bind(daemon, { public_id: "c-2", root: project("elsewhere"), mcp: [fx] })
    assert_equal "200", code, answer.inspect
    assert_equal ["fx"], answer.fetch("environment").fetch("mcp").map { |row| row.fetch("name") }, "a runner elsewhere: the servers still land"
    assert_equal "c-2", daemon.context.environments.servers.owner_of("mcp__fx__lookup")
  end

  # A daemon nobody registered a registrar on (no rho-mcp): 422
  # `mcp_unavailable` for any `mcp:` list, the empty one included — the
  # seam's first rule; a body without the member is untouched by it.
  def test_mcp_is_422_mcp_unavailable_without_a_registrar
    daemon = ready(api())
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    assert_equal "200", bind(daemon, { public_id: "c-1", root: project("src") }).first

    code, answer = bind(daemon, { public_id: "c-1", mcp: [RhoTest::ConversationServers.stdio("fx")] })

    assert_equal ["422", "mcp_unavailable"], [code, answer.dig("error", "code")], answer.inspect
    assert_match(/enable rho-mcp/, answer.dig("error", "message"))
    assert_empty get_environment(daemon, "c-1").last.fetch("environment").fetch("mcp")
    assert_equal ["422", "mcp_unavailable"], bind(daemon, { public_id: "c-1", mcp: [] }).then { |c, a| [c, a.dig("error", "code")] }
    assert_equal "200", bind(daemon, { public_id: "c-1", directories: [] }).first, "no member: the record's door as ever"
  end

  # A registrar that will not open a set at all — its own
  # `Rho::Runner::Error`, rho-mcp's `Closed` once its shutdown ladder ran
  # — is 503 `daemon_stopping`, the daemon's own sentence; the anchor
  # holds nothing, and over a held set the held set went first and the
  # union lost its names.
  def test_mcp_is_503_daemon_stopping_when_the_registrar_will_not_open_a_set
    api = api()
    daemon = ready(api, config: agent_mode("extension_paths" => [servers_extension]))
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    assert_equal "200", bind(daemon, { public_id: "c-1", root: project("src") }).first
    fx = RhoTest::ConversationServers.stdio("fx")
    stopping = fx.merge("command" => "stopping")

    code, answer = bind(daemon, { public_id: "c-1", mcp: [stopping] })

    assert_equal ["503", "daemon_stopping", "The local daemon is stopping"],
      [code, answer.dig("error", "code"), answer.dig("error", "message")], answer.inspect
    assert_empty daemon.context.environments.servers.names
    assert_empty get_environment(daemon, "c-1").last.fetch("environment").fetch("mcp")
    assert_empty closed, "nothing was held: nothing closed"

    assert_equal "200", bind(daemon, { public_id: "c-1", mcp: [fx] }).first
    declared = api.configuration_declarations.length
    assert_includes declared_names(api), "mcp__fx__lookup"
    code, answer = bind(daemon, { public_id: "c-1", mcp: [stopping] })

    assert_equal ["503", "daemon_stopping"], [code, answer.dig("error", "code")], answer.inspect
    assert_equal ["c-1"], closed, "the held set went first"
    assert_empty daemon.context.environments.servers.names
    assert_empty get_environment(daemon, "c-1").last.fetch("environment").fetch("mcp")
    assert_equal declared + 1, api.configuration_declarations.length, "the union lost the dropped set's names"
    refute_includes declared_names(api), "mcp__fx__lookup"
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_match(/event=mcp_servers\.registrar_closed anchor=c-1 error_class="?[^ ]*ConversationServersExtension::Stopping"? /, log)
    refute_includes log, "hunter2", "the env value never reaches the log"
  end
end
