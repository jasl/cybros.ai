require "test_helper"

# THE HANDOFF EXTENSION'S ROUTES: the
# discovery listing with this daemon's marks, and the one verb that moves
# where a host's runner-kind calls land — the collision check BEFORE the
# bind, the bind through the SDK, the store row following it and the
# profile's union declaration written once and only when its bytes move.
# Presence is the kernel's word for a FOREIGN executor; rho's own planes
# print local truth elsewhere (`rho status`).
class HandoffExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  OWN = NexusDoubles.remote_runner("0199-runner", display_name: "Helper", root: "/home/rho",
    tools: %w[read write bash].map { |name| NexusDoubles.served_tool(name) }, presence: "online")
  # A runner elsewhere: two names rho lacks, no collision.
  ELSEWHERE = NexusDoubles.remote_runner("0199-h", presence: "offline", last_seen_at: "2026-09-08T00:00:00Z")
  # A runner announcing `read` in OTHER bytes than this rho's Coding
  # extension — the byte collision the union must never carry twice.
  COLLIDING = NexusDoubles.remote_runner("0199-k", display_name: "Other",
    tools: [NexusDoubles.served_tool("read", description: "an echo of the path"), NexusDoubles.served_tool("slow_read")],
    presence: "not_yet_seen")

  def store = host_store

  def conversation_host(public_id) = Rho::Host::Conversation.new(public_id: public_id)

  def api(**options)
    NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG,
      executors: [OWN, ELSEWHERE, COLLIDING], **options)
  end

  def ready(api, config: Rho::Config.from_hash("kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys))
    member_ready(boot(config: config), api, identity: RUNNER_IDENTITY)
  end

  def runners(daemon) = JSON.parse(request(daemon, :get, "/runners", token: bearer(daemon)).body)

  def handoff(daemon, host, executor)
    response = request(daemon, :post, "/handoff", token: bearer(daemon),
      body: { public_id: host, executor_public_id: executor })
    [response.code, JSON.parse(response.body)]
  end

  def declared_names(api, index = -1)
    api.configuration_declarations.fetch(index).dig("configuration", "tool_definitions")
      .map { |entry| entry.dig("function", "name") }
  end

  # THE LISTING: every runner discovery answers for this
  # profile, each with the kernel's presence word, its announced root and
  # tool count, marked `own` for this machine's row, `selected` for the
  # settings' choice and `bound_hosts` for every followed host on it; a
  # runner whose bytes collide with the union names the tool.
  def test_runners_lists_discovery_with_this_daemons_marks
    api = api()
    daemon = ready(api)
    File.write(daemon.home.settings_path, JSON.generate("runner" => "0199-h"))
    store.remember(conversation_host("c-1"), workspace: "ws-1", loop: "al-1", runner: "0199-h")
    store.remember(Rho::Host::AgentLoop.new(public_id: "al-2"), workspace: "ws-1", runner: "0199-h")
    store.remember(conversation_host("c-3"), workspace: "ws-1", runner: "0199-runner")

    document = runners(daemon)

    assert_equal "0199-h", document.fetch("selection")
    rows = document.fetch("runners")
    assert_equal %w[0199-runner 0199-h 0199-k], rows.map { |row| row.fetch("public_id") }
    own, elsewhere, colliding = rows
    assert_equal({ "public_id" => "0199-runner", "display_name" => "Helper", "presence" => "online",
                   "last_seen_at" => nil, "root" => "/home/rho", "tools" => %w[read write bash], "own" => true,
                   "selected" => false, "bound_hosts" => %w[c-3], "conflict" => nil }, own)
    assert_equal({ "public_id" => "0199-h", "display_name" => "Elsewhere", "presence" => "offline",
                   "last_seen_at" => "2026-09-08T00:00:00Z", "root" => "/srv/elsewhere",
                   "tools" => %w[slow_read slow_write], "own" => false, "selected" => true,
                   "bound_hosts" => %w[c-1 al-2], "conflict" => nil }, elsewhere)
    assert_equal ["0199-k", "not_yet_seen", false, false, [], "read"],
      colliding.values_at("public_id", "presence", "own", "selected", "bound_hosts", "conflict")
    assert_equal [["/agent_api/v1/executors", { "kind" => "runner" }]],
      api.requests.select { |path, _| path == "/agent_api/v1/executors" }.map { |path, _, params| [path, params] },
      "discovery narrowed to the runner kind"
  end

  # THE VERB: the target read from discovery, the bytes checked
  # against the union, the bind through the SDK on the host's own door,
  # the row's runner moved, and the profile re-declared ONCE with the
  # union — a second identical handoff is the kernel's plain 200 and
  # moves no byte.
  def test_handoff_binds_through_the_sdk_remembers_the_row_and_declares_the_union_once
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", loop: "al-1", model: "m/x", runner: "0199-runner")

    code, answer = handoff(daemon, "al-1", "0199-h")

    assert_equal "200", code, answer.inspect
    assert_equal({ "type" => "conversation", "public_id" => "c-1" }, answer.fetch("host"), "resolved as `say` resolves: by the backing loop")
    assert_equal({ "executor_public_id" => "0199-h", "display_name" => "Elsewhere", "presence" => "offline",
                   "last_seen_at" => "2026-09-08T00:00:00Z" }, answer.fetch("runner"))
    assert_equal "0199-runner", answer.fetch("previous")
    assert_equal "old runner 0199-runner at /home/rho, new runner 0199-h at /srv/elsewhere — the tree is not synced",
      answer.fetch("warning"), "the roots differ: said once, never a refusal"
    assert_equal [["c-1", "0199-h"]], api.handoffs
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-1/runner") }, "the conversation's own door")
    row = store.find("c-1")
    assert_equal ["0199-h", "al-1", "m/x"], [row.runner, row.loop, row.model], "the binding moved; nothing else did"

    assert_equal 1, api.configuration_declarations.length, "the union, declared once"
    names = declared_names(api)
    assert_includes names, "slow_read"
    assert_includes names, "slow_write"
    assert_includes names, "bash"
    assert_equal 1, names.count("read"), "one name, one entry"
    machine = names - %w[compose task]
    assert_equal machine.sort, machine, "the union is canonical by name, as the kernel stores it"
    assert_equal %w[compose task], names.last(2), "the kernel's bytes close the list"

    code, answer = handoff(daemon, "c-1", "0199-h")
    assert_equal "200", code, answer.inspect
    assert_equal "0199-h", answer.fetch("previous")
    refute answer.key?("warning"), "the same runner on both sides: nothing to sync"
    assert_equal 1, api.configuration_declarations.length, "the same bytes: nothing re-declared"
    assert_equal 1, File.read(daemon.home.log_path, encoding: Encoding::UTF_8).scan("event=profile.declared").length
  end

  # THE RECORD FOLLOWS THE HANDOFF: the
  # conversation's environment record is the conversation's row, so right
  # after the bind the verb relays it to the new runner — `environment_bind`
  # as a request loop on that runner's announced park, the conversation id
  # on the input — and the answer says what the runner knows; a row with
  # no record relays nothing, and a loop host has no record to follow.
  def test_handoff_relays_the_conversations_record_to_the_new_runner_after_the_bind
    api = api(
      executors: [OWN, NexusDoubles.remote_runner("0199-h", booted_at: "2026-09-17T06:00:00Z"), COLLIDING],
      task_detail: { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "environment_bind",
                     "output" => "bound", "result" => { "is_error" => false },
                     "structured_content" => { "applied" => true, "resolved" => false, "booted_at" => "2026-09-17T06:00:00Z" },
                     "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-17T00:00:00Z" }
    )
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    store.remember(conversation_host("c-2"), workspace: "ws-1", model: "m/x", runner: "0199-runner")
    api.stock_store_entry("c-1", namespace: "rho.environment", key: "binding",
      value: { "root" => "/home/me/proj", "directories" => [], "anchor" => "c-1" })

    code, answer = handoff(daemon, "c-1", "0199-h")

    assert_equal "200", code, answer.inspect
    assert_equal({ "runner" => "0199-h", "state" => "confirmed", "booted_at" => "2026-09-17T06:00:00Z", "resolved" => false },
      answer.fetch("environment").fetch("relayed"), "told, and the root is not on that host: placement zero there")
    relayed = api.loop_creates.select { |body| body.dig("agent_loop", "steps", 0, "tool", "name") == "environment_bind" }
    assert_equal 1, relayed.length
    assert_equal({ "root" => "/home/me/proj", "directories" => [], "anchor" => "c-1", "conversation_public_id" => "c-1" },
      relayed.fetch(0).dig("agent_loop", "steps", 0, "tool", "input"))
    assert_equal "0199-h", relayed.fetch(0).dig("agent_loop", "runner_executor_public_id")
    assert_equal [["c-1", "0199-h"]], api.handoffs, "the bind first"

    code, answer = handoff(daemon, "c-2", "0199-h")
    assert_equal "200", code, answer.inspect
    refute answer.key?("environment"), "no record: nothing to relay"
    assert_equal 1, api.loop_creates.length
  end

  # THE TREE-SYNC WARNING: the old binding read off the row
  # then discovery (fresh, at warning time), the target off the discovery
  # read the verb just made; ONE line naming the fields that
  # differ, nothing when they match, nothing when a side is unknown — an
  # unbound row, or an old runner discovery no longer lists.
  def test_handoff_warns_once_on_a_tree_mismatch_and_never_when_a_side_matches_or_is_unknown
    twin = NexusDoubles.remote_runner("0199-twin", root: "/srv/elsewhere", branch: "main")
    branched = NexusDoubles.remote_runner("0199-branched", root: "/srv/elsewhere", branch: "feature")
    api = api(executors: [OWN, ELSEWHERE, twin, branched])
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-h")
    store.remember(conversation_host("c-2"), workspace: "ws-1", runner: "0199-twin")
    store.remember(conversation_host("c-3"), workspace: "ws-1", runner: "0199-gone")
    store.remember(conversation_host("c-4"), workspace: "ws-1")

    code, answer = handoff(daemon, "c-1", "0199-twin")
    assert_equal "200", code, answer.inspect
    refute answer.key?("warning"), "the same root; the branch H never announced is unknown, not different"
    assert(api.requests.any? { |path, _| path == "/agent_api/v1/executors/0199-h" }, "the old binding, read from discovery")

    code, answer = handoff(daemon, "c-2", "0199-branched")
    assert_equal "200", code, answer.inspect
    assert_equal "old runner 0199-twin on branch main, new runner 0199-branched on branch feature — the tree is not synced",
      answer.fetch("warning")

    code, answer = handoff(daemon, "c-3", "0199-h")
    assert_equal "200", code, answer.inspect
    assert_equal "0199-gone", answer.fetch("previous")
    refute answer.key?("warning"), "an old runner discovery no longer lists is unknown"

    code, answer = handoff(daemon, "c-4", "0199-h")
    assert_equal "200", code, answer.inspect
    refute answer.key?("warning"), "an unbound row has no old tree to compare"
  end

  # THE OLD SIDE IS READ FRESH: a runner re-announces its tree on every repoint — `rho do
  # --dir` moves this home's own runner, and a runner elsewhere moves on its own — while
  # the daemon's discovery cache holds the document as it was LAST read. A warning built
  # from the cache said "old runner at run 1's root" against a fresh target at run 2's, on
  # two homes that stood at the same root. So the verb reads the previous binding from
  # discovery at warning time, the way it reads the target, and the cache learns what it
  # read.
  def test_handoff_reads_the_old_binding_fresh_so_a_repointed_home_never_warns_stale
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-runner")
    store.remember(conversation_host("c-2"), workspace: "ws-1", runner: "0199-runner")

    code, answer = handoff(daemon, "c-1", "0199-h")
    assert_equal "200", code, answer.inspect
    assert_equal "old runner 0199-runner at /home/rho, new runner 0199-h at /srv/elsewhere — the tree is not synced",
      answer.fetch("warning"), "the first handoff: the roots differ, and the cache now holds /home/rho"

    # This home repoints to the target's tree and re-announces; the cache
    # still says /home/rho.
    api.reannounce_executor(NexusDoubles.remote_runner("0199-runner", display_name: "Helper", root: "/srv/elsewhere",
      tools: %w[read write bash].map { |name| NexusDoubles.served_tool(name) }, presence: "online"))

    code, answer = handoff(daemon, "c-2", "0199-h")
    assert_equal "200", code, answer.inspect
    refute answer.key?("warning"), "the same root on both sides NOW: the old binding was read fresh, not off the cache"
    assert_equal 2, api.requests.count { |path, _| path == "/agent_api/v1/executors/0199-runner" },
      "one discovery read of the old binding per handoff"
    assert_equal "/srv/elsewhere", daemon.loops.remote_runner("0199-runner").environment["root"],
      "the cache learned the fresh document"
  end

  # THE COLLISION: a target announcing a name this rho declares
  # in OTHER bytes is refused before anything reaches the kernel — the
  # model would otherwise be offered two readings of one name.
  def test_handoff_refuses_a_byte_collision_before_the_bind
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-runner")

    code, answer = handoff(daemon, "c-1", "0199-k")

    assert_equal "409", code
    assert_equal "declaration_conflict", answer.dig("error", "code")
    assert_equal "read is declared with different bytes by this rho and by 0199-k; " \
                 "a handoff would offer the model two readings of one name", answer.dig("error", "message")
    assert_empty api.handoffs, "nothing reached the kernel"
    assert_equal "0199-runner", store.find("c-1").runner
    assert_empty api.configuration_declarations
  end

  # A host nobody here follows, a target discovery does not list, and the
  # kernel's own refusal — each as itself.
  def test_handoff_refuses_an_unfollowed_host_an_unknown_target_and_relays_the_kernel
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-runner")

    code, answer = handoff(daemon, "c-9", "0199-h")
    assert_equal ["404", "host_not_followed"], [code, answer.dig("error", "code")]
    assert_match(/attach it first/, answer.dig("error", "message"))

    code, answer = handoff(daemon, "c-1", "0199-zz")
    assert_equal ["404", "runner_not_found"], [code, answer.dig("error", "code")]
    assert_empty api.handoffs

    assert_equal "400", handoff(daemon, "c-1", "").first
    assert_equal "400", handoff(daemon, "", "0199-h").first

    refusal = CybrosAgent::Response.new(status: 409, headers: {},
      body: { "error" => { "code" => "runner_not_eligible", "message" => "revoked" } })
    daemon.wire.api_transport = api(handoff: refusal)
    code, answer = handoff(daemon, "c-1", "0199-h")
    assert_equal ["409", "runner_not_eligible", "revoked"], [code, answer.dig("error", "code"), answer.dig("error", "message")]
    assert_equal "0199-runner", store.find("c-1").runner, "a refused handoff moves nothing here"
  end

  # THE STANDALONE HOST takes the same verb on its own door.
  def test_handoff_on_a_standalone_loop_uses_the_loop_door
    api = api()
    daemon = ready(api)
    store.remember(Rho::Host::AgentLoop.new(public_id: "al-4"), workspace: "ws-1")

    code, answer = handoff(daemon, "al-4", "0199-h")

    assert_equal "200", code, answer.inspect
    assert_equal({ "type" => "agent_loop", "public_id" => "al-4" }, answer.fetch("host"))
    assert_nil answer["previous"], "a row that knew no binding"
    assert(api.requests.any? { |path, _| path.end_with?("/agent_loops/al-4/runner") })
    assert_equal "0199-h", store.find("al-4").runner
  end

  # A runner-mode rho opens no conversation and holds no member plane, so
  # it ships without the extension; an agent-mode rho is exactly the
  # daemon that names remote runners, and keeps it.
  def test_the_extension_ships_in_full_and_agent_mode_and_not_in_runner_mode
    assert_includes Rho::Extensions.defaults_for("full"), Rho::Extensions::Handoff
    assert_includes Rho::Extensions.defaults_for("agent"), Rho::Extensions::Handoff
    refute_includes Rho::Extensions.defaults_for("runner"), Rho::Extensions::Handoff
    assert_equal "rho.handoff", Rho::Extensions::Handoff::NAME
  end
end
