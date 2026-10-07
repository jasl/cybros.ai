require "test_helper"
require "tmpdir"

# WHICH HOSTS THIS MACHINE FOLLOWS. A daemon that restarts follows nothing,
# so without this file every run it authored kept advancing on the server
# with nobody watching: no `rho watch`, no steer reaching a live round, and
# for a gated run, no gate. ONE store, host-keyed: a
# standalone run Ops authored, or a conversation rho opened — and for a
# conversation, the turn and the run backing it, the id every run-grain
# verb is given.
class HostStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rho-hosts")
    @path = File.join(@dir, "hosts.json")
    @now = Time.utc(2026, 9, 4, 12, 0, 0)
    @store = Rho::HostStore.new(@path, clock: -> { @now })
  end

  def teardown = FileUtils.rm_rf(@dir)

  def run_public_id(public_id) = Rho::Host::Run.new(public_id: public_id)
  def conversation(public_id) = Rho::Host::Conversation.new(public_id: public_id)

  def test_a_remembered_host_survives_a_new_reader
    @store.remember(run_public_id("al-1"), workspace: "ws-1")
    @store.remember(conversation("c-2"), workspace: "ws-1", live: false, turn: "t-2", run_public_id: "al-2",
      model: "openrouter/x", notes: { "rho.until" => { "command" => "make test", "attempts" => 3 } })

    rows = Rho::HostStore.new(@path).rows
    assert_equal [%w[run al-1], %w[conversation c-2]], rows.map { |row| [row.host_type, row.host_public_id] }
    assert_equal [run_public_id("al-1"), conversation("c-2")], rows.map(&:host)
    assert rows.first.live
    refute rows.last.live, "a detached follower is remembered as detached"
    assert_equal({}, rows.first.notes, "a host nothing shaped carries no notes")
    assert_nil rows.first.run_public_id, "a run is its own host and backs no turn"
    assert_equal %w[t-2 al-2], [rows.last.turn, rows.last.run_public_id]
    assert_nil rows.last.model
    assert_empty rows.last.notes
    assert_equal "make test", @store.rows.last.notes.dig("rho.until", "command")
    refute JSON.parse(File.read(@path)).fetch("hosts").last.key?("notes")
    assert_equal "2026-09-04T12:00:00Z", rows.first.remembered_at
  end

  # The later call is the current truth about a host — a follower
  # detached, a gate attached — so it replaces the row rather than
  # appending one; and the two host kinds never collide on an id.
  def test_remembering_a_host_twice_keeps_one_row_per_host
    @store.remember(run_public_id("al-1"), workspace: "ws-1")
    @store.remember(run_public_id("al-1"), workspace: "ws-1", live: false)
    @store.remember(conversation("al-1"), workspace: "ws-1")

    assert_equal 2, @store.rows.length
    refute @store.rows.first.live
    assert @store.rows.last.live
  end

  # Only the authoring call knows what the extensions recorded, and only
  # the follow that learned the backing run knows it; an attach or a
  # detach after them says nothing about either and must not lose them.
  def test_a_later_call_that_says_nothing_about_notes_or_the_run_keeps_them
    surface = { "kind" => "model_task", "instructions" => "cwd is /tmp" }
    @store.remember(conversation("c-1"), workspace: "ws-1", notes: { "rho.until" => surface }, run_public_id: "al-1")
    @store.remember(conversation("c-1"), workspace: "ws-1", live: false)

    assert_equal({ "rho.until" => surface }, @store.rows.first.notes)
    assert_equal "al-1", @store.rows.first.run_public_id
    @store.remember(conversation("c-1"), workspace: "ws-1", notes: {}, run_public_id: "al-2")
    assert_equal({}, @store.rows.first.notes, "notes said out loud replace what stood")
    assert_equal "al-2", @store.rows.first.run_public_id, "and so does a run said out loud"
  end

  def test_an_explicit_nil_clears_the_previous_backing_run_on_disk
    @store.remember(conversation("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1")
    @store.remember(conversation("c-1"), workspace: "ws-1", run_public_id: nil)

    restored = Rho::HostStore.new(@path)
    assert_nil restored.find("c-1").run_public_id
    assert_equal "t-1", restored.find("c-1").turn
    assert_nil restored.find("al-1")
  end

  # Policy stays in memory until the next handle hydrates it from Nexus.
  def test_model_policy_survives_silence_without_becoming_local_persistence
    @store.remember(conversation("c-1"), workspace: "ws-1", model: "openrouter/x")
    @store.remember(conversation("c-1"), workspace: "ws-1", live: false, turn: "t-2")
    assert_equal "openrouter/x", @store.rows.first.model
    assert_nil Rho::HostStore.new(@path).rows.first.model
  end

  # A verb is handed a RUN id (the eleven paid lanes parse one off `rho
  # do`); the row it names is the host's own, or the conversation whose
  # turn that run backs.
  def test_find_answers_the_hosts_own_id_and_the_backing_run
    @store.remember(run_public_id("al-1"), workspace: "ws-1")
    @store.remember(conversation("c-2"), workspace: "ws-1", run_public_id: "al-2")

    assert_equal run_public_id("al-1"), @store.find("al-1").host
    assert_equal conversation("c-2"), @store.find("c-2").host
    assert_equal conversation("c-2"), @store.find("al-2").host
    assert_nil @store.find("al-9")
  end

  def test_forgetting_the_last_row_removes_the_file
    @store.remember(run_public_id("al-1"), workspace: "ws-1")
    @store.remember(run_public_id("al-2"), workspace: "ws-1")

    @store.forget(run_public_id("al-1"))
    assert_equal %w[al-2], @store.rows.map(&:host_public_id)

    @store.forget(run_public_id("al-2"))
    assert_empty @store.rows
    refute File.exist?(@path), "nothing left to read at the next boot"
  end

  # A machine that ran a thousand runs must not read a thousand rows at
  # boot; the newest are kept and the eviction is reported rather than
  # leaving a person to wonder why an old run stopped being followed.
  def test_the_cap_keeps_the_newest_and_says_what_it_dropped
    (Rho::HostStore::MAX_ROWS + 2).times { |n| @store.remember(run_public_id("al-#{n}"), workspace: "ws-1") }

    rows = @store.rows
    assert_equal Rho::HostStore::MAX_ROWS, rows.length
    assert_equal "al-2", rows.first.host_public_id
    evicted = @store.remember(run_public_id("al-fresh"), workspace: "ws-1")
    assert_equal %w[al-2], evicted
  end

  def test_rows_from_another_workspace_are_kept_and_filtered_by_the_caller
    @store.remember(run_public_id("al-1"), workspace: "ws-1")
    @store.remember(run_public_id("al-2"), workspace: "ws-2")

    assert_equal %w[al-1], @store.rows.select { |row| row.workspace == "ws-1" }.map(&:host_public_id)
  end

  # A hand-edited or half-written file is the caller's problem to report,
  # not a parse crash inside a boot path.
  def test_a_corrupt_document_surfaces_as_a_state_error
    File.write(@path, "{not json")
    File.chmod(0o600, @path)

    assert_raises(Rho::StateError) { Rho::HostStore.new(@path).rows }
  end

  # The wire's own spelling of a host is what a row keeps and what
  # `Host.from` reads back; a type nobody hosts is a KeyError, never a
  # silent default.
  def test_a_row_rebuilds_its_host_by_the_wire_type
    assert_equal run_public_id("al-1"), Rho::Host.from("run", "al-1")
    assert_equal conversation("c-1"), Rho::Host.from("conversation", "c-1")
    assert_raises(KeyError) { Rho::Host.from("inference_request", "os-1") }
  end

  # THE CONVERSATION A HOST IS: a grant records the
  # conversation it was made on off the run's binding — the host itself,
  # for a conversation; none for a standalone run — through the host,
  # never a branch on its kind.
  def test_a_host_names_the_conversation_it_is_or_none
    assert_equal "c-1", conversation("c-1").conversation_public_id
    assert_nil run_public_id("al-1").conversation_public_id
  end

  # THE BINDING AND THE LEAD'S RUNNER: `runner` is where the
  # host's runner-kind calls land as this daemon last learned it,
  # THE ANSWERER: the foreign profile a conversation is
  # answered by, nil when rho itself answers — kept by a call that says
  # nothing (every `say` after the open), cleared by one that says nil,
  # and the one fact `foreign?` reads.
  def test_the_answerer_survives_silence_and_clears_on_nil
    @store.remember(conversation("c-1"), workspace: "ws-1", answerer: "peer-1")
    assert_equal "peer-1", @store.rows.first.answerer
    assert_predicate @store.rows.first, :foreign?

    @store.remember(conversation("c-1"), workspace: "ws-1", live: false, turn: "t-2")
    row = Rho::HostStore.new(@path).rows.first
    assert_equal "peer-1", row.answerer, "silence keeps it"
    assert_equal "peer-1", row.to_h.fetch("answerer")

    @store.remember(conversation("c-1"), workspace: "ws-1", answerer: nil)
    refute_predicate @store.rows.first, :foreign?, "nil said out loud: rho answers"
    refute @store.rows.first.to_h.key?("answerer")
  end

  # `runner` the binding as this daemon last learned it — kept by a call
  # that says nothing, cleared by one that says nil (a reap names no
  # executor). The lead rides every turn, so no row remembers whom the
  # last one was rendered for.
  def test_the_runner_survives_silence_and_clears_on_nil
    @store.remember(conversation("c-1"), workspace: "ws-1", runner: "0199-h")
    assert_equal "0199-h", @store.rows.first.runner

    @store.remember(conversation("c-1"), workspace: "ws-1", live: false, turn: "t-2")
    row = Rho::HostStore.new(@path).rows.first
    assert_equal ["0199-h", "t-2"], [row.runner, row.turn], "silence keeps it"

    @store.remember(conversation("c-1"), workspace: "ws-1", runner: nil)
    assert_nil @store.rows.first.runner, "nil said out loud clears the binding"
  end
end
