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
    assert_equal 2, store.calls.length

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
    assert_equal 3, empty.calls.length, "a Miss is memoized for the run"
    assert_nil table.binding_for("c-2", plane: plane(bare), run_public_id: "al-2")
    assert_equal 4, empty.calls.length, "a new run reads again"
  end

  # A GET that fails keeps the last memo standing, logs once per
  # conversation, and never refuses the turn; a fetch 404 is the row gone
  # — the miss path.
  def test_a_failing_read_keeps_the_memo_and_logs_once_and_a_404_is_the_miss_path
    store = FakeStore.new([row(value)])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    table.read("c-1", plane: plane(client))

    store.fail_reads(CybrosAgent::TransportError.new("down"))
    read = table.read("c-1", plane: plane(client))
    assert_equal binding, read.binding, "the last memo stands"
    table.read("c-1", plane: plane(client))
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

  # A walk that cannot see the parent falls to zero with `environment.unresolved`.
  def test_a_walk_that_cannot_see_the_parent_falls_to_zero_and_says_so
    client = FakeClient.new(conversations: { "c-2" => FakeConversation.new(store: FakeStore.new, parent: "c-hidden") })
    table = environments(client)

    assert_nil table.binding_for("c-2", plane: plane(client), run_public_id: "al-1")
    assert_match(/event=environment\.unresolved .*conversation=c-2/, log_text)
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

    assert_equal binding, table.binding_for("c-1-side", plane: plane(client))
    assert_empty store.calls
  end

  # ---- the runner elsewhere ----

  # THE RELAY, KEYED BY THE RUNNER'S PROCESS LIFE: the first assertion
  # refreshes discovery and relays `environment_bind` on the runner's
  # announced park with the conversation id on the input; the fiber
  # records `confirmed` with the runner's `booted_at`; the same tuple on
  # the same boot relays nothing more; a new `booted_at` on the refreshed
  # document relays once more; a reconnect with the same `booted_at`
  # (a moved `connected_at`) relays nothing.
  def test_assert_remote_relays_once_per_tuple_and_boot_and_again_when_the_boot_moves
    learned = []
    documents = { "0199-h" => discovered("0199-h", booted_at: "2026-09-17T06:00:00Z", connected_at: "2026-09-17T06:01:00Z") }
    client = FakeClient.new(answers: [relay_answer, relay_answer(booted_at: "2026-09-17T09:00:00Z"), relay_answer],
      executors: documents)
    table = environments(client, inline: true, learned: learned)

    relayed = table.assert_remote("c-1", "0199-h", binding, plane: plane(client))

    assert_equal ["confirmed", true, "2026-09-17T07:00:00Z"], [relayed.state, relayed.resolved, relayed.booted_at]
    assert_equal ["0199-h"], client.executors.shows, "the document is refreshed first"
    assert_equal 1, learned.length, "and put back into the daemon's cache"
    request = client.requests.fetch(0)
    assert_equal value.merge("conversation_public_id" => "c-1"), request[:input]
    assert_nil request[:timeout_ms], "the runner's announced park governs the row"
    assert_equal "author", request[:rules].fetch(0).fetch("origin"), "the runner's own rules judge it on the path"

    assert_equal "confirmed", table.assert_remote("c-1", "0199-h", binding, plane: plane(client)).state
    assert_equal 1, client.requests.length, "the same tuple on the same boot: nothing relayed"

    documents["0199-h"] = discovered("0199-h", booted_at: "2026-09-17T06:00:00Z", connected_at: "2026-09-17T06:30:00Z")
    table.assert_remote("c-1", "0199-h", binding, plane: plane(client))
    assert_equal 1, client.requests.length, "a reconnect with the same booted_at: nothing"

    documents["0199-h"] = discovered("0199-h", booted_at: "2026-09-17T08:30:00Z")
    relayed = table.assert_remote("c-1", "0199-h", binding, plane: plane(client))
    assert_equal ["confirmed", "2026-09-17T09:00:00Z"], [relayed.state, relayed.booted_at]
    assert_equal 2, client.requests.length, "a restarted runner is told again"
    assert_equal 2, log_text.scan("event=environment.relayed").length

    table.assert_remote("c-1", "0199-h", binding(directories: [@other]), plane: plane(client))
    assert_equal 3, client.requests.length, "a moved tuple relays"
  end

  # `connected_at` is the fallback key for a runner announcing no
  # `booted_at`; one announcing neither is asserted once per host boot.
  def test_the_boot_key_falls_back_to_connected_at_and_a_document_with_neither_asserts_once
    documents = { "0199-h" => discovered("0199-h", connected_at: "2026-09-17T06:00:00Z"),
                  "0199-k" => discovered("0199-k") }
    client = FakeClient.new(answers: [relay_answer, relay_answer, relay_answer], executors: documents)
    table = environments(client, inline: true)

    table.assert_remote("c-1", "0199-h", binding, plane: plane(client))
    table.assert_remote("c-1", "0199-h", binding, plane: plane(client))
    assert_equal 1, client.requests.length
    documents["0199-h"] = discovered("0199-h", connected_at: "2026-09-17T06:30:00Z")
    table.assert_remote("c-1", "0199-h", binding, plane: plane(client))
    assert_equal 2, client.requests.length, "a moved connected_at re-asserts"

    table.assert_remote("c-2", "0199-k", binding(anchor: "c-2"), plane: plane(client))
    table.assert_remote("c-2", "0199-k", binding(anchor: "c-2"), plane: plane(client))
    assert_equal 3, client.requests.length, "neither: once per host boot"
  end

  # THE GATE: the verb waits the gate and proceeds with `pending`
  # while the fiber runs on; the fiber records `confirmed`, or CLEARS the
  # entry on any other terminal so the next edge tries again; a runner
  # without the tool (`tool_not_served`) is logged `environment.unrelayed`
  # once and not relayed again on the same boot.
  def test_the_gate_proceeds_pending_and_the_fiber_records_or_clears
    release = Queue.new
    answer = relay_answer
    slow = Object.new
    slow.define_singleton_method(:wait_for_tool_result) { |poll:| release.pop; answer }
    client = FakeClient.new(executors: { "0199-h" => discovered("0199-h", booted_at: "2026-09-17T06:00:00Z") })
    client.workspace("ws-1").runs.define_singleton_method(:start_tool_call) { |**| slow }
    table = environments(client)

    relayed = table.assert_remote("c-1", "0199-h", binding, plane: plane(client), gate: 0.05)
    assert_equal ["pending", nil, nil], [relayed.state, relayed.resolved, relayed.booted_at]
    assert_equal "pending", table.assert_remote("c-1", "0199-h", binding, plane: plane(client), gate: 0.05).state,
      "an assertion in flight is not relayed twice"
    release << true
    join_spawned
    assert_equal "confirmed", table.asserted("c-1", "0199-h").state

    failing = FakeClient.new(answers: [relay_answer(status: "timed_out", error_key: "tool_timeout"), relay_answer],
      executors: { "0199-h" => discovered("0199-h", booted_at: "2026-09-17T06:00:00Z") })
    table = environments(failing, inline: true)
    relayed = table.assert_remote("c-1", "0199-h", binding, plane: plane(failing))
    assert_equal "unavailable", relayed.state
    assert_nil table.asserted("c-1", "0199-h"), "cleared: the next edge tries again"
    assert_equal "confirmed", table.assert_remote("c-1", "0199-h", binding, plane: plane(failing)).state
    assert_equal 2, failing.requests.length

    bare = FakeClient.new(answers: [relay_answer(status: "failed", error_key: "tool_not_served")],
      executors: { "0199-x" => discovered("0199-x", booted_at: "2026-09-17T06:00:00Z") })
    table = environments(bare, inline: true)
    assert_equal "unavailable", table.assert_remote("c-1", "0199-x", binding, plane: plane(bare)).state
    assert_equal "unavailable", table.assert_remote("c-1", "0199-x", binding, plane: plane(bare)).state
    assert_equal 1, bare.requests.length, "a runner without the tool is not asked again on the same boot"
    assert_equal 1, log_text.scan("event=environment.unrelayed").length
  end

  def test_an_unserved_environment_tool_refused_at_acceptance_is_unavailable_until_the_runner_restarts
    documents = { "0199-x" => discovered("0199-x", booted_at: "2026-09-17T06:00:00Z") }
    client = FakeClient.new(executors: documents)
    attempts = 0
    client.workspace("ws-1").runs.define_singleton_method(:start_tool_call) do |**|
      attempts += 1
      raise CybrosAgent::Api::InvalidRequest.new("Refused: tool_not_served", code: "tool_not_served")
    end
    table = environments(client, inline: true)

    2.times do
      assert_equal "unavailable", table.assert_remote("c-1", "0199-x", binding, plane: plane(client)).state
    end
    assert_equal 1, attempts, "an acceptance refusal is cached for this Runner's boot"
    assert_equal "unavailable", table.asserted("c-1", "0199-x").state
    assert_equal 1, log_text.scan("event=environment.unrelayed").length
    refute_includes log_text, "event=environment.relay_failed"

    documents["0199-x"] = discovered("0199-x", booted_at: "2026-09-17T09:00:00Z")
    assert_equal "unavailable", table.assert_remote("c-1", "0199-x", binding, plane: plane(client)).state
    assert_equal 2, attempts, "a restarted Runner is asked again"
  end

  def test_other_acceptance_refusals_clear_the_environment_assertion_for_the_next_edge
    client = FakeClient.new(executors: { "0199-x" => discovered("0199-x", booted_at: "2026-09-17T06:00:00Z") })
    attempts = 0
    client.workspace("ws-1").runs.define_singleton_method(:start_tool_call) do |**|
      attempts += 1
      raise CybrosAgent::Api::InvalidRequest.new("Refused: invalid_tool_route", code: "invalid_tool_route")
    end
    table = environments(client, inline: true)

    2.times do
      assert_equal "unavailable", table.assert_remote("c-1", "0199-x", binding, plane: plane(client)).state
      assert_nil table.asserted("c-1", "0199-x")
    end
    assert_equal 2, attempts
    assert_equal 2, log_text.scan("event=environment.relay_failed").length
    refute_includes log_text, "event=environment.unrelayed"
  end

  # A runner discovery cannot show relays nothing and says so; a document
  # handed in by the verb is not fetched again.
  def test_assert_remote_with_a_handed_document_reads_no_discovery_and_an_unlisted_runner_is_unavailable
    client = FakeClient.new(answers: [relay_answer])
    table = environments(client, inline: true)

    relayed = table.assert_remote("c-1", "0199-h", binding, plane: plane(client),
      document: discovered("0199-h", booted_at: "2026-09-17T06:00:00Z"))
    assert_equal "confirmed", relayed.state
    assert_empty client.executors.shows

    assert_equal "unavailable", table.assert_remote("c-1", "0199-gone", binding, plane: plane(client)).state
    assert_equal 1, client.requests.length
  end

  # THE MAINTENANCE CYCLE: every followed row bound to a remote
  # runner is re-asserted once per cycle — a restart with no prompt pending
  # is caught within a cycle; own-runner rows and unbound rows cost nothing.
  def test_reassert_stale_re_asserts_every_remote_bound_row_once_per_cycle
    documents = { "0199-h" => discovered("0199-h", booted_at: "2026-09-17T06:00:00Z") }
    client = FakeClient.new(
      conversations: { "c-1" => FakeConversation.new(store: FakeStore.new([row(value, key: "binding/0199-h")])),
                       "c-2" => FakeConversation.new(store: FakeStore.new) },
      answers: [relay_answer, relay_answer], executors: documents
    )
    table = environments(client, inline: true)
    rows = [
      { host: Rho::Host::Conversation.new(public_id: "c-1"), runner: "0199-different-default" },
      { host: Rho::Host::Conversation.new(public_id: "c-2"), runner: "0199-h" },
      { host: Rho::Host::Conversation.new(public_id: "c-3"), runner: "0199-runner" },
      { host: Rho::Host::Run.new(public_id: "al-1"), runner: "0199-h" },
      { host: Rho::Host::Conversation.new(public_id: "c-4"), runner: nil },
    ]

    table.reassert_stale(rows)

    assert_equal 1, client.requests.length, "the one remote-bound conversation with a record"
    assert_equal ["0199-h"], client.executors.shows.uniq
    table.reassert_stale(rows)
    assert_equal 1, client.requests.length, "the same boot: nothing"
    documents["0199-h"] = discovered("0199-h", booted_at: "2026-09-17T09:00:00Z")
    table.reassert_stale(rows)
    assert_equal 2, client.requests.length, "the restarted runner is told again within a cycle"
  end

  # ---- the runner slot's receiving table ----

  # A binding RECEIVED from a host elsewhere wins over the store; an absent
  # root applies with `resolved: false`; a protected root is refused.
  def test_receive_wins_over_the_store_and_answers_resolved_by_this_host
    store = FakeStore.new([row(value(@other))])
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)

    assert table.receive("c-1", binding), "resolved: the root is on this host"
    assert_equal binding, table.binding_for("c-1", plane: plane(client))
    assert_empty store.calls, "received: the store is never read"
    placed = table.toolsets.for(task("c-1"))
    assert_equal binding, placed.binding
    assert_equal @project, placed.env.root
    # A spawned child on this slot resolves by its PARENT's received
    # binding — the inbox row's `parent_public_id` — with no call_tool in the path.
    child = table.toolsets.for(task("c-9", parent: "c-1", run_public_id: "al-9"))
    assert_equal binding, child.binding, "the parent's received binding, no store read"
    assert_empty store.calls

    refute table.receive("c-2", binding(File.join(@root, "absent"), anchor: "c-2")), "absent on this host: unresolved"
    assert_equal "protected_root", table.refusal_for(Rho.root)
    assert_equal "not_a_directory", table.refusal_for(File.join(@root, "absent"))
    assert_nil table.refusal_for(@project)
    assert_match(/event=environment\.received .*conversation=c-1/, log_text)
  end

  # THE WINDOW: a slot with NO member plane — a runner-mode
  # daemon, restarted mid-conversation or claiming a child before the
  # host's call_tool lands — was told nothing and can read nothing, so the
  # claim lands on placement zero AND the log says so: `environment.
  # unresolved reason=not_received`, once per conversation, however many
  # claims fall in the window. Told afterwards, it resolves with no
  # further line.
  def test_a_slot_with_no_member_plane_told_nothing_lands_on_zero_and_says_so_once
    runner = environments(FakeClient.new, member_plane: ->(**) { })

    assert_nil runner.resolve("c-7"), "nothing received, nothing readable: zero"
    assert_nil runner.resolve("c-7", "c-8"), "an unknown parent tells it nothing either"
    placed = runner.toolsets.for(task("c-7", run_public_id: "al-7"))
    assert_nil placed.binding
    assert_equal @project, placed.env.root, "placement zero"
    unresolved = log_text.each_line.grep(/event=environment\.unresolved /)
    assert_equal 1, unresolved.length, "once per conversation, not per claim:\n#{log_text}"
    assert_match(/conversation=c-7 .*reason=not_received/, unresolved.first)

    assert runner.receive("c-7", binding)
    assert_equal binding, runner.resolve("c-7"), "told: resolved"
    assert_equal 1, log_text.each_line.grep(/event=environment\.unresolved /).length, "no line once told"
  end

  # A CHILD WITH NO ROW OF ITS OWN resolves through the parent the inbox
  # row names before any projection read: the walk takes the hint.
  def test_a_row_naming_its_parent_walks_from_it_without_a_projection_read
    client = FakeClient.new(conversations: {
      "c-1" => FakeConversation.new(store: FakeStore.new([row(value)])),
      "c-2" => FakeConversation.new(store: FakeStore.new, parent: "c-1"),
    })
    table = environments(client)

    assert_equal binding, table.resolve("c-2", "c-1")
    assert_equal 0, client.workspace("ws-1").conversation("c-2").fetches, "the row's parent, not the projection's"
  end

  # THE HOST'S ORDER IS MEMO → STORE → WALK: a child whose OWN row exists before its first
  # claim resolves to it, never to the parent's memo — the parent shortcut is the RECEIVED
  # table's (a runner resolves a spawned child by its parent's received binding); the
  # host's memo of the parent is the walk's, after the child's own store is read. On a
  # runner-mode slot (no member plane) the parent's received binding, memoized under a
  # child, carries a grandchild's chain before the host's call_tool for the child lands.
  def test_a_childs_own_row_wins_over_the_parents_memo_on_a_host_and_a_runner_chains_through_its_memo
    client = FakeClient.new(conversations: {
      "c-1" => FakeConversation.new(store: FakeStore.new([row(value)])),
      "c-2" => FakeConversation.new(store: FakeStore.new([row(value(@other, anchor: "c-2"), public_id: "se-2")]), parent: "c-1"),
    })
    table = environments(client)
    table.read("c-1", plane: plane(client))

    assert_equal binding(@other, anchor: "c-2"), table.resolve("c-2", "c-1"), "the child's own row, not the parent's memo"

    runner = environments(FakeClient.new, member_plane: ->(**) { })
    runner.receive("c-1", binding)
    assert_equal binding, runner.resolve("c-2", "c-1"), "the parent's received binding"
    assert_equal binding, runner.resolve("c-3", "c-2"), "the grandchild through the child's memo"
    assert_nil runner.resolve("c-4", "c-9"), "an unknown parent: zero"
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
    assert_same zero, handle.for(task(nil)), "a standalone run_public_id: zero"
    assert_same zero, handle.for(task("c-5", run_public_id: "al-5")), "no record: zero"
    assert_equal registry.names.sort, handle.names.sort

    placed = handle.for(task("c-1"))
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

  def test_settings_replace_both_slots_without_losing_received_bindings_or_the_mutation_queue
    table = environments(FakeClient.new(conversations: {}))
    table.receive("c-1", binding(@other))
    runner = table.toolsets
    agent = table.agent_toolsets(registry)
    before = runner.for(task("c-1"))
    original_agent = agent.for(task("c-1"))
    empty = Rho::Runner::Extensions::Loader.call(builtin: []).registry

    table.configure(config: Rho::Config.from_hash({ "plugins" => { "rho.coding" => { "configuration_version" => 1, "configuration" => { "bash_timeout_seconds" => 7 } } } }),
      registry: empty, agent_registry: empty)

    assert_same runner, table.toolsets
    assert_same agent, table.agent_toolsets(empty)
    assert_empty runner.names
    assert_empty agent.names
    after = runner.for(task("c-1"))
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
  # root (two `git init`s on one shadow store, the loser recording nil).
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

    assert_equal [{ conversation: "c-1", runner: nil, root: @project, directories: [], anchor: "c-1", source: "conversation", relayed: nil, fs: nil, mcp: [] }],
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
