require "test_helper"
require "socket"
require "tmpdir"
require_relative "../support/environment_fixtures"

# THE CONVERSATION'S ENVIRONMENT, THE HOST'S SIDE: one `store_entries` row per conversation —
# `rho.environment`/`binding`, value `{root, directories, anchor}` — read
# every turn, written only when a verb names a root set, under the
# read-compare-write discipline; the parent walk for a spawned child;
# the top-down copy at the child edge; the call_tool to a runner elsewhere
# keyed by that runner's process life; the placement a claim resolves
# on the worker. All of it against an SDK double: the store's four
# verbs, the discovery read, the request run.
class DaemonEnvironmentsTest < Minitest::Test
  include RhoTest::EnvironmentFixtures

  # ---- the read edge ----

  # THE READ EVERY TURN MAKES: a memo miss lists the conversation's
  # entries, finds the row and fetches its value; a memo hit fetches by
  # its public id alone (the value and a fresh `lock_version`); nothing
  # there is a Miss, memoized per run so the next run reads again.
  def test_read_lists_then_fetches_on_a_miss_and_fetches_by_id_on_a_hit
    store = FakeStore.new([row(value)])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)

    read = table.read("c-1", plane: plane(client))

    assert_equal [binding, "conversation", "se-1", 0], [read.binding, read.source, read.public_id, read.lock_version]
    assert_equal [[:list, nil], [:fetch, "se-1"]], store.calls
    assert_equal binding, table.binding_for("c-1", plane: plane(client)), "the memo, no request"
    assert_equal 3, store.calls.length

    store.patch(value(@other))
    again = table.read("c-1", plane: plane(client))
    assert_equal [binding(@other), 1], [again.binding, again.lock_version], "a person's PATCH is read at the next turn"
    assert_equal [:fetch, "se-1"], store.calls.last, "a hit fetches by id alone"
    assert_equal binding(@other), table.binding_for("c-1", plane: plane(client)), "the memo is the turn's"

    empty = FakeStore.new
    bare = FakeClient.new(conversations: { "c-2" => FakeConversation.new(store: empty) })
    table = environments(bare)
    assert_nil table.read("c-2", plane: plane(bare)).binding
    assert_equal "default", table.read("c-2", plane: plane(bare)).source
    assert_equal 2, empty.calls.length, "a verb's read is never memoized as a miss for a run"
    assert_nil table.binding_for("c-2", plane: plane(bare), run_public_id: "al-1")
    assert_nil table.binding_for("c-2", plane: plane(bare), run_public_id: "al-1")
    assert_equal 4, empty.calls.length, "each capture reads the current record"
    assert_nil table.binding_for("c-2", plane: plane(bare), run_public_id: "al-2")
    assert_equal 5, empty.calls.length, "a new run reads again"
  end

  # A GET that fails keeps the last memo standing, logs once per
  # conversation, and never refuses the turn; a fetch 404 is the row gone
  # — the miss path.
  def test_a_failing_read_refuses_capture_and_a_404_is_the_miss_path
    store = FakeStore.new([row(value)])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    table.read("c-1", plane: plane(client))

    store.fail_reads(CybrosAgent::TransportError.new("down"))
    2.times { assert_raises(CybrosAgent::TransportError) { table.read("c-1", plane: plane(client)) } }
    assert_equal 1, log_text.scan("event=environment.unreadable").length, "logged once per conversation"

    store.fail_reads(nil)
    store.rows.clear
    assert_nil table.read("c-1", plane: plane(client)).binding, "a fetch 404 is the row gone: the miss path"
  end

  # ---- the write edge ----

  # THE READ-COMPARE-WRITE: nothing there → `create` under a per-call
  # key; an equal tuple → no request; a differing one → `update` under the
  # last-read `lock_version`; `key_taken` → another writer won, so the
  # update path; one retry on a stale version; a second stale is 409
  # `environment_contended` — never a force.
  def test_bind_creates_updates_under_the_read_version_and_is_a_no_op_when_equal
    store = FakeStore.new
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)

    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client))

    assert_equal [binding, 0, "se-1"], [bound.binding, bound.lock_version, bound.public_id]
    create = store.calls.find { |call| call.first == :create }
    assert_equal [NAMESPACE, KEY, value], create[1..3]
    assert_match(/\A[0-9a-f-]{36}\z/, create[4], "a per-call idempotency key")

    table.bind("c-1", root: @project, directories: [], plane: plane(client))
    assert_empty store.calls.select { |call| %i[create update].include?(call.first) }.drop(1), "equal: no request"

    bound = table.bind("c-1", root: @project, directories: [@other], plane: plane(client))
    assert_equal [1, [@other]], [bound.lock_version, bound.binding.directories]
    assert_equal [:update, "se-1", value(@project, directories: [@other]), 0], store.calls.last
  end

  def test_bind_takes_the_update_path_on_key_taken_and_retries_once_on_a_stale_version
    store = FakeStore.new
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    # Another writer lands between the read and the create.
    original = store.method(:create)
    store.define_singleton_method(:create) do |**args|
      store.singleton_class.remove_method(:create)
      original.call(namespace: NAMESPACE, key: KEY, value: { "root" => "/theirs", "directories" => [], "anchor" => "c-1" },
        idempotency_key: "theirs")
      original.call(**args)
    end

    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client))

    assert_equal [binding, 1], [bound.binding, bound.lock_version], "key_taken: read again, then the update path"
    assert_equal :update, store.calls.last.first

    # A stale version once: re-read, retry under the fresh one.
    store.patch(value(@other))
    stale = store.method(:update)
    moved = value(@other, directories: ["/x"])
    store.define_singleton_method(:update) do |public_id, value:, lock_version:|
      store.singleton_class.remove_method(:update)
      store.patch(moved)
      stale.call(public_id, value: value, lock_version: lock_version)
    end
    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client))
    assert_equal [binding, 4], [bound.binding, bound.lock_version]
    assert_equal 2, store.calls.count { |call| call.first == :update && call[2] == value && call[3] >= 2 }, "one retry"

    # A second stale is the contended refusal — never a force.
    store.define_singleton_method(:update) do |*|
      raise CybrosAgent::Api::Conflict.new("stale", code: "stale_object")
    end
    refusal = table.bind("c-1", root: @other, directories: [], plane: plane(client))
    assert_kind_of Rho::Daemon::Refusal, refusal
    assert_equal [409, "environment_contended"], [refusal.status, refusal.code]
  end

  def test_creation_binding_preserves_an_existing_own_record_and_initializes_a_fork_copy
    store = FakeStore.new([row(value(@other))])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    before = store.rows.first
    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client), initialize_only: true)
    assert_equal @other, bound.root
    assert_equal before, store.rows.first
    assert_empty store.calls.select { |call| %i[create update].include?(call.first) }

    store.patch(value(@other).merge("anchor" => "parent"))
    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client), initialize_only: true)
    assert_equal binding, bound.binding
    assert_equal "c-1", store.rows.first.value.fetch("anchor")
  end

  def test_creation_binding_keeps_another_writers_record_on_key_taken
    store = FakeStore.new
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    original = store.method(:create)
    winner = value(@other)
    store.define_singleton_method(:create) do |**args|
      store.singleton_class.remove_method(:create)
      original.call(namespace: NAMESPACE, key: KEY, value: winner, idempotency_key: "winner")
      original.call(**args)
    end
    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client), initialize_only: true)
    assert_equal [@other, 0], [bound.root, bound.lock_version]
    assert_equal winner, store.rows.first.value
    refute store.calls.any? { |call| call.first == :update }
  end

  def test_creation_binding_keeps_a_child_binding_that_wins_the_fork_copy_update
    store = FakeStore.new([row(value(@other).merge("anchor" => "parent"))])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    original = store.method(:update)
    winner = value(@other)
    store.define_singleton_method(:update) do |*args, **kwargs|
      store.singleton_class.remove_method(:update)
      store.patch(winner)
      original.call(*args, **kwargs)
    end
    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client), initialize_only: true)
    assert_equal [@other, 1], [bound.root, bound.lock_version]
    assert_equal winner, store.rows.first.value
    assert_equal 1, store.calls.count { |call| call.first == :update }
  end

  # A stale version whose re-read is ALREADY the tuple asked for is done
  # with no second write; the kernel's own bound refusals cross as themselves.
  def test_bind_is_done_when_the_re_read_matches_and_relays_the_kernels_bounds
    store = FakeStore.new([row(value(@other))])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    asked = value
    store.define_singleton_method(:update) do |*|
      store.singleton_class.remove_method(:update)
      store.patch(asked)
      raise CybrosAgent::Api::Conflict.new("stale", code: "stale_object")
    end

    bound = table.bind("c-1", root: @project, directories: [], plane: plane(client))
    assert_equal [binding, 1], [bound.binding, bound.lock_version]
    assert_equal 0, store.calls.count { |call| call.first == :update }, "the re-read matched: no second write"

    store.define_singleton_method(:update) do |*|
      raise CybrosAgent::Api::Conflict.new("full", code: "entry_limit_reached")
    end
    refusal = table.bind("c-1", root: @other, directories: [], plane: plane(client))
    assert_equal [409, "entry_limit_reached"], [refusal.status, refusal.code]
  end

  # `clear` deletes the record under the read version; nothing there is done.
  def test_clear_deletes_the_record_and_the_memo_falls_to_the_default
    store = FakeStore.new([row(value)])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    table.read("c-1", plane: plane(client))

    cleared = table.clear("c-1", plane: plane(client))

    assert_nil cleared.binding
    assert_equal "default", cleared.source
    assert_equal [:delete, "se-1", 0], store.calls.last
    assert_empty store.rows
    assert_nil table.binding_for("c-1", plane: plane(client))
    assert_equal "default", table.clear("c-1", plane: plane(client)).source, "nothing there: done"
  end

  # ---- inheritance ----

  # THE UPWARD WALK: a child with no record reads its parent's
  # through the projection's `parent`, two deep, memoizes under the child
  # and writes the child's own copy with the PARENT's anchor; `key_taken`
  # on that copy is done.
  def test_the_parent_walk_finds_a_record_two_deep_and_writes_the_childs_copy
    parent_store = FakeStore.new([row(value(anchor: "c-1"))])
    child_store = FakeStore.new
    grandchild_store = FakeStore.new
    client = FakeClient.new(conversations: {
      "c-1" => FakeConversation.new(store: parent_store),
      "c-2" => FakeConversation.new(store: child_store, parent: "c-1"),
      "c-3" => FakeConversation.new(store: grandchild_store, parent: "c-2"),
    })
    table = environments(client)

    found = table.binding_for("c-3", plane: plane(client), run_public_id: "al-3")

    assert_equal binding(anchor: "c-1"), found, "the parent's tuple, the parent's anchor"
    assert_equal "parent", table.memo("c-3").source
    assert_equal "conversation", table.read("c-3", plane: plane(client)).source, "the copy is the child's own row from here"
    copy = grandchild_store.entry
    refute_nil copy, "the child's copy is written"
    assert_equal value(anchor: "c-1"), copy.value
    assert_equal 1, client.workspace("ws-1").conversation("c-3").fetches
    assert_equal binding(anchor: "c-1"), table.binding_for("c-3", plane: plane(client), run_public_id: "al-4"), "the memo"

    grandchild_store.rows.clear
    grandchild_store.define_singleton_method(:create) do |**|
      raise CybrosAgent::Api::Conflict.new("taken", code: "key_taken")
    end
    orphan = FakeClient.new(conversations: {
      "c-1" => FakeConversation.new(store: parent_store),
      "c-9" => FakeConversation.new(store: grandchild_store, parent: "c-1"),
    })
    assert_equal binding(anchor: "c-1"), environments(orphan).binding_for("c-9", plane: plane(orphan)),
      "key_taken on the copy: another writer won, and the walk's answer stands"
  end

  # An unreadable parent refuses capture instead of selecting a default.
  def test_a_walk_that_cannot_see_the_parent_refuses_capture
    client = FakeClient.new(conversations: { "c-2" => FakeConversation.new(store: FakeStore.new, parent: "c-hidden") })
    table = environments(client)

    assert_raises(CybrosAgent::Api::NotFound) { table.binding_for("c-2", plane: plane(client), run_public_id: "al-1") }
  end

  # THE TOP-DOWN COPY AT THE CHILD EDGE: for every child new to the
  # list, the parent's tuple is created on the child's store (anchor
  # unchanged); `key_taken` is done; a child on a REMOTE runner is relayed.
  def test_adopt_children_preserves_source_binding_without_copying_to_a_new_default
    parent_store = FakeStore.new([row(value)])
    own_child = FakeStore.new
    remote_child = FakeStore.new
    taken = FakeStore.new([row(value("/theirs", anchor: "c-3"), public_id: "se-9")])
    client = FakeClient.new(
      conversations: {
        "c-1" => FakeConversation.new(store: parent_store),
        "c-2" => FakeConversation.new(store: own_child, parent: "c-1", runner: "0199-runner"),
        "c-3" => FakeConversation.new(store: taken, parent: "c-1", runner: "0199-runner"),
        "c-4" => FakeConversation.new(store: remote_child, parent: "c-1", runner: "0199-h"),
      },
      answers: [relay_answer], executors: { "0199-h" => discovered("0199-h", booted_at: "2026-09-17T06:00:00Z") }
    )
    table = environments(client, inline: true)

    table.adopt_children("c-1", %w[c-2 c-3 c-4])

    assert_equal value, own_child.entry.value
    assert_equal value("/theirs", anchor: "c-3"), taken.entry.value, "key_taken: never overwritten"
    assert_equal value, remote_child.entry.value
    assert_empty client.requests, "the child's default never imports the parent's agent binding"
    assert_equal binding, table.binding_for("c-4", plane: plane(client)), "memoized under its original source"
    assert_nil table.binding_for("c-4", plane: plane(client), runner: "0199-h")
  end

  # A side is born with the kernel's copy: the parent's tuple is memoized
  # under the side at once, no request.
  def test_remember_copy_memoizes_the_parents_tuple_under_the_side
    store = FakeStore.new
    client = FakeClient.new(conversations: { "c-1-side" => FakeConversation.new(store: store) })
    table = environments(client)

    table.remember_copy("c-1-side", binding)

    assert_equal binding, table.memo("c-1-side").binding
    assert_nil table.binding_for("c-1-side", plane: plane(client)), "future capture reads durable state"
    refute_empty store.calls
  end

  def test_missing_member_plane_refuses_to_capture_a_default
    table = environments(FakeClient.new, member_plane: ->(**) { nil })
    assert_raises(CybrosAgent::Api::InvalidRequest) { table.read("c-1") }
  end

  # ---- the placement ----

  # PLACEMENT ZERO AND THE RUNNER SLOT'S HANDLE: the default
  # root's env under the runner gem's `Toolsets` (the per-root-set memo,
  # the miss per run and the notices are the gem's); a claim with no
  # conversation lands on zero, one with a record on that root's env;
  # `rho env` rebuilds zero under the SAME handle, so the runner stands,
  # and the fixed agent placement follows the new zero.
  def test_the_slot_handle_resolves_claims_through_the_record_and_zero_moves_under_it
    client = FakeClient.new(conversations: {
      "c-1" => FakeConversation.new(store: FakeStore.new([row(value(@other))])),
      "c-5" => FakeConversation.new(store: FakeStore.new),
    })
    table = environments(client)
    handle = table.toolsets

    zero = table.zero
    assert_equal @project, zero.env.root
    assert_nil zero.binding
    assert_same zero, handle.zero
    assert_raises(ArgumentError) { handle.for(task(nil, binding: nil)) }
    assert_raises(ArgumentError) { handle.for(task("c-5", binding: nil)) }
    assert_equal registry.names.sort, handle.names.sort

    placed = handle.for(task("c-1", binding: binding(@other)))
    assert_equal [File.realpath(@other), [], "c-1"], [placed.env.root, placed.env.directories, placed.binding.anchor],
      "the gem spells the placement's root by its real path"
    assert_equal @project, placed.env.documents_root, "the documents are the default root's"
    assert_same zero.env.mutation_queue, placed.env.mutation_queue, "ONE mutation queue per runner"
    agent = table.agent_toolsets(registry)
    assert_same zero.env, agent.zero.env, "the agent slot rides zero's env"

    moved = File.join(@root, "moved")
    FileUtils.mkdir_p(moved)
    @project = moved
    rebuilt = table.rebuild_zero
    refute_same zero, rebuilt
    assert_same rebuilt, table.zero
    assert_same rebuilt, handle.zero, "the same handle: the runner was not rebuilt"
    assert_equal moved, rebuilt.env.root
    assert_same rebuilt.env, agent.zero.env, "the existing agent handle follows the new root"
    assert_same rebuilt.env, table.agent_toolsets(registry).zero.env, "the fixed placement follows"
    assert_nil rebuilt.env.checkpoints, "no store opener: no store"
  end

  def test_settings_replace_both_slots_without_changing_captured_bindings_or_the_mutation_queue
    table = environments(FakeClient.new(conversations: {}))
    runner = table.toolsets
    agent = table.agent_toolsets(registry)
    before = runner.for(task("c-1", binding: binding(@other)))
    original_agent = agent.for(task("c-1"))
    empty = Rho::Runner::Extensions::Loader.call(builtin: []).registry

    table.configure(config: Rho::Config.from_hash({ "plugins" => { "rho.coding" => { "configuration_version" => 1, "configuration" => { "bash_timeout_seconds" => 7 } } } }),
      registry: empty, agent_registry: empty)

    assert_same runner, table.toolsets
    assert_same agent, table.agent_toolsets(empty)
    assert_empty runner.names
    assert_empty agent.names
    after = runner.for(task("c-1", binding: binding(@other)))
    assert_equal before.binding, after.binding, "the received conversation binding survives"
    assert_equal File.realpath(@other), after.env.root
    assert_equal 7, after.env.bash_timeout_seconds
    assert_equal 7, agent.for(task("c-1")).env.bash_timeout_seconds
    assert_same before.env.mutation_queue, after.env.mutation_queue
    assert_nil after.env.processes
    assert_includes before.toolset.names, "bash", "a call already holding its placement may finish"
    assert_includes original_agent.toolset.names, "bash"
    assert_raises(KeyError) { after.toolset.fetch("bash") }
  end

  # ONE BUILD UNDER CONCURRENT FIRST TOUCH: two slots mounted on two
  # threads (the maintenance cycle's adoption beside a verb's) reach
  # placement zero together; the second waits for the first's build and
  # shares it — never a second env, toolset and store open on the same
  # root; checkpoint initialization belongs to that one placement.
  def test_placement_zero_is_built_once_under_concurrent_first_touch
    entered = Queue.new
    release = Queue.new
    table = environments(FakeClient.new, default_root: -> { entered << true; release.pop; @project })
    threads = 2.times.map { Thread.new { table.zero } }

    entered.pop
    sleep 0.2
    assert_equal 0, entered.size, "the second first-touch waits for the first build: one build, one store"
    2.times { release << true }
    zeros = threads.map(&:value)

    assert_same zeros.fetch(0), zeros.fetch(1), "both slots ride the one placement zero"
    assert_same zeros.fetch(0), table.zero
  end

  # ---- the listing and the memo bound ----

  def test_listing_answers_the_memo_for_the_followed_rows
    client = FakeClient.new(conversations: {
      "c-1" => FakeConversation.new(store: FakeStore.new([row(value)])),
      "c-2" => FakeConversation.new(store: FakeStore.new),
    })
    table = environments(client)
    table.read("c-1", plane: plane(client))
    table.read("c-2", plane: plane(client))

    listing = table.listing([Rho::Host::Conversation.new(public_id: "c-1"), Rho::Host::Conversation.new(public_id: "c-2")])

    assert_equal [{ conversation: "c-1", runner: nil, root: @project, directories: [], anchor: "c-1", source: "conversation", fs: nil, mcp: [] }],
      listing
  end

  def test_the_record_memo_is_bounded_and_evicted_by_last_touch
    stores = (1..(Rho::Environments::RECORDS_MAX + 1)).to_h do |n|
      ["c-#{n}", FakeConversation.new(store: FakeStore.new([row(value(anchor: "c-#{n}"))]))]
    end
    client = FakeClient.new(conversations: stores)
    table = environments(client)
    stores.each_key { |id| table.read(id, plane: plane(client)) }

    assert_nil table.memo("c-1"), "the oldest touch is evicted"
    refute_nil table.memo("c-2")
    first = stores.fetch("c-1").store_entries
    table.read("c-1", plane: plane(client))
    assert_equal :list, first.calls.last(2).first.first, "a lost entry costs one list + fetch"
  end

  # ---- the file-system port ----

  # THE PORTS TABLE, KEYED BY ANCHOR: the door registers
  # `{url, token, read, write, client}`
  # under the record's anchor and the table answers the port per call —
  # a child's or a side's rows find the parent's port by their binding's
  # anchor with no lookup of their own; a second registration on the
  # anchor replaces the first; `nil` clears. The port's description
  # carries no token.
  def test_register_port_keys_the_port_by_anchor_and_a_child_reaches_its_parents
    table = environments(FakeClient.new)
    refute table.port_live?("c-1")
    assert_nil table.port_for("c-1")

    port = table.register_port("c-1", url: "http://127.0.0.1:4321", token: "bearer-1", read: true, write: false, client: "zed")

    assert_kind_of Rho::Extensions::Environment::FsPort, port
    assert_same port, table.port_for("c-1")
    assert table.port_live?("c-1")
    assert_same port, table.port_for(binding(@project, anchor: "c-1").anchor), "a copy's anchor is the parent's port"
    assert_nil table.port_for("c-2")
    assert_equal({ client: "zed", read: true, write: false }, port.describe)
    refute_includes port.inspect, "bearer-1"

    assert_same port, table.register_port("c-1", url: "http://127.0.0.1:4321", token: "bearer-1", read: true, write: false, client: "zed"),
      "the same registration again (a prompt's re-assertion) is a no-op: the held port stands"
    assert_equal 1, log_text.scan(/event=fs_port\.registered/).length, "and nothing is logged for it"
    refute_predicate port, :dropped?

    replaced = table.register_port("c-1", url: "http://127.0.0.1:4322", token: "bearer-2", read: true, write: true, client: "zed")
    assert_same replaced, table.port_for("c-1")
    assert replaced.serves?(:write)
    assert_predicate port, :dropped?, "a different registration replaces"
    assert_equal 2, log_text.scan(/event=fs_port\.registered .*anchor=c-1/).length
    assert_match(/event=fs_port\.dropped .*anchor=c-1 reason=replaced/, log_text)
    refute_includes log_text, "bearer-", "the bearer never reaches the log"

    table.drop_port("c-1", reason: "cleared")
    assert_nil table.port_for("c-1")
    assert_match(/event=fs_port\.dropped .*anchor=c-1 reason=cleared/, log_text)
  end

  # THE DROPS: `:host_ended`
  # drops the anchor's port and nothing of another anchor's; a port that
  # answered `Unavailable` — here a URL nobody listens on — is dropped by
  # the runner's `FsPort.ask` through `drop`, which reaches the table:
  # `fs_port.dropped` logged ONCE, the next lookup nil so the next read is
  # the disk's; a replaced port dropping late never drops its successor.
  def test_host_ended_and_unavailable_drop_the_port_once
    table = environments(FakeClient.new)
    closed = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{closed.local_address.ip_port}"
    closed.close
    table.register_port("c-1", url: url, token: "b", read: true, write: true, client: "zed")
    table.register_port("c-2", url: url, token: "b", read: true, write: true, client: "zed")

    table.host_ended("c-1")
    assert_nil table.port_for("c-1")
    assert table.port_live?("c-2"), "another anchor's port stands"
    assert_equal 1, log_text.scan(/event=fs_port\.dropped .*anchor=c-1 reason=host_ended/).length

    port = table.port_for("c-2")
    error = assert_raises(Rho::Runner::FsPort::Unavailable) { port.read_text("/srv/a", line: 1, limit: 1) }
    assert_same port, table.port_for("c-2"), "the client raises; the runner's ask drops"
    port.drop(error.message)
    assert_nil table.port_for("c-2"), "dropped on Unavailable"
    port.drop(error.message)
    assert_equal 1, log_text.scan(/event=fs_port\.dropped .*anchor=c-2/).length, "said once"
    assert_match(/anchor=c-2 reason=unavailable/, log_text)

    stale = table.register_port("c-3", url: url, token: "b", read: true, write: true, client: "zed")
    assert_same stale, table.register_port("c-3", url: url, token: "b", read: true, write: true, client: "zed"), "the same again: kept"
    fresh = table.register_port("c-3", url: url, token: "b2", read: true, write: true, client: "zed")
    assert_predicate stale, :dropped?, "replaced"
    stale.drop("late")
    assert_same fresh, table.port_for("c-3"), "a replaced port dropping late never drops its successor"
    assert_equal 1, log_text.scan(/event=fs_port\.dropped .*anchor=c-3/).length
    assert_match(/anchor=c-3 reason=replaced/, log_text)
  end

  # THE RENDER SCOPE: the conventions describer asks whether the lead
  # being rendered has a live port; outside a render nothing has one.
  def test_describing_lead_scopes_the_ports_liveness_to_one_render
    table = environments(FakeClient.new)
    table.register_port("c-1", url: "http://127.0.0.1:4321", token: "b", read: true, write: true, client: "zed")

    refute table.lead_port?, "no render in progress"
    assert table.describing_lead("c-1") { table.lead_port? }
    refute table.describing_lead("c-2") { table.lead_port? }
    refute table.describing_lead(nil) { table.lead_port? }
    refute table.lead_port?, "the scope ended with the block"
  end

  # THE LIVE TABLE'S ROW says whether the anchor has a port and with
  # which flags — never the token or the URL.
  def test_listing_carries_the_ports_description
    store = FakeStore.new([row(value)])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    table.read("c-1", plane: plane(client))
    host = Struct.new(:public_id).new("c-1")

    assert_nil table.listing([host]).fetch(0).fetch(:fs)
    table.register_port("c-1", url: "http://127.0.0.1:4321", token: "b", read: true, write: false, client: "zed")
    assert_equal({ client: "zed", read: true, write: false }, table.listing([host]).fetch(0).fetch(:fs))
    assert_equal({ client: "zed", read: true, write: false }, table.port_description("c-1"))
    assert_nil table.port_description("c-2")
  end
end
