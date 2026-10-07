require "test_helper"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/peer_program"
require "support/realtime_lane"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/red_square_png"
require "support/steward_session"
require "stringio"

# CONVERSATION ACCESS CONTROL (per-principal access without groups): every conversation carries a
# DEFAULT level for everyone the entries do not name (`full | read | none`) and one entry per named
# principal; the creator and the answerer are full by derivation; `none` conceals — to such a
# principal the conversation is absent on every door, exactly as a tombstone — and `read` reads but
# is refused every write by name. The exit runs the rule where only the rule can explain what it
# sees: TWO SDK peers (A, B — agent programs under the steward that declare nothing) in an
# ACCOUNT-WIDE ROOM the steward opened, where B has write standing and a 403 is the level's alone;
# and rho, the third agent, in its own DEDICATED workspace, where the `none → read` flip is pinned
# as 404 → 200 on list/show — reads are never fenced by dedication, so a change there is the ACL's
# alone ("read cannot post" in a dedicated workspace would pass for the wrong reason).
#
# ONE CEREMONY PER FILE (the `side_conversation` shape): the steward's
# session, the room, the two peers and rho's daemon are booted once for
# every case here — three device grants of the per-IP budget — and
# stopped when the run ends. The mock provider echoes; what is asserted is
# who sees what, never the words.
#
# A kernel-stamped receipt remains accepted when its attributed principal has only read access;
# Nexus unit coverage pins that distinction from caller-origin input. This journey checks peer posts
# at full access (202), no access (404), and read access (403).
class ConversationAclTest < Minitest::Test
  include E2E::RealtimeLane

  MODEL = "dev/mock-text".freeze
  POLL = 1
  AWAIT_SECONDS = 90
  RED_SQUARE = E2E::RedSquarePng.bytes

  World = Struct.new(:daemon, :home, :steward, :actor, :rho_workspace_public_id, :room_public_id,
    :peer_a, :peer_b, :shared_human, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-conversation-acl-e2e")
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home)
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor,
        shared_human: provisioning.shared_human)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.rho_workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      # THE ROOM: account-wide, the STEWARD's — an agent's `account_wide`
      # create is refused (`Workspaces::Create#create_for_agent`), and a
      # room every member of the account can enter is where B's write
      # standing is real.
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      @world.room_public_id = steward_client.workspaces.create(
        name: "ACL room #{SecureRandom.hex(3)}", access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).public_id
      @world.peer_a = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "acl-a")
      @world.peer_b = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "acl-b")
      @world
    end

    def await_workspace_adopted(daemon)
      daemon.await("the daemon never reported workspace adopted") do
        document = daemon.status
        workspace = document["workspace"]
        raise "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == "adopted" ? workspace.fetch("public_id") : nil
      end
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      begin
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      FileUtils.remove_entry(world.home) if world.home && File.directory?(world.home)
    end
  end

  Minitest.after_run { ConversationAclTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @room = @world.room_public_id
    @a = @world.peer_a
    @b = @world.peer_b
    @shared = @world.shared_human
    @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @shared_client = CybrosAgent::Client.new(base_url: @base_url, credential: @shared.member_token)
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
  rescue StandardError => error
    warn "Could not capture the conversation ACL E2E logs: #{error.class}: #{error.message}"
  end

  # CASE 1 — DEFAULT FULL. Born `full` with no entries: every member of the room lists and reads A's
  # conversation, and B — a peer with write standing in the room — posts a `message` (a speaker's
  # word).
  def test_a_conversation_is_born_full_and_every_member_of_the_room_reads_and_a_peer_posts
    created = a_conversations.create(idempotency_key: SecureRandom.uuid, title: "open")
    assert_equal "full", created.conversation.access.default
    assert_empty created.conversation.access.entries
    id = created.public_id

    assert_includes listed_ids(@b.client), id, "B lists it"
    assert_equal "full", chat_for(@b.client, id).fetch.access.default
    assert_equal id, chat_for(@steward_client, id).fetch.public_id, "the steward reads it"
    assert_equal id, chat_for(@shared_client, id).fetch.public_id, "the other Human reads it"

    posted = chat_for(@b.client, id).inputs.create(kind: "message", text: "B was here", idempotency_key: SecureRandom.uuid)
    assert_equal "message", posted.input.kind, "a full peer posts: the first of the three levels of a peer's post"
  end

  # CASE 2 — DEFAULT NONE WITH ONE ENTRY. A opens `none` naming the other Human at `read`. To B the
  # conversation is ABSENT: the working list omits it and every door — show, turns, events, the
  # inputs queue, a post, the store, memory, a fork, the cable — answers 404, never a 403 that
  # admits the row exists. A reads everything; the named Human reads and is refused a post by name;
  # THE STEWARD — the workspace's OWNER — is not listed and finds it absent too (no owner
  # carve-out).
  def test_none_conceals_on_every_door_and_read_reads_but_cannot_post
    created = a_conversations.create(idempotency_key: SecureRandom.uuid, title: "restricted",
      access: { default: "none", entries: [{ user_public_id: @shared.public_id, level: "read" }] })
    id = created.public_id
    access = created.conversation.access
    assert_equal "none", access.default
    assert_equal [[@shared.public_id, "human", "read"]], access.entries.map { |e| [e.user_public_id, e.kind, e.level] }

    refute_includes listed_ids(@b.client), id, "the working list conceals it from B"
    b_chat = chat_for(@b.client, id)
    doors = {
      "show" => -> { b_chat.fetch },
      "turns" => -> { b_chat.turns.list },
      "events" => -> { b_chat.events },
      "inputs" => -> { b_chat.inputs.list },
      "post" => -> { b_chat.inputs.create(kind: "message", text: "hi", idempotency_key: SecureRandom.uuid) },
      "store" => -> { b_chat.store_entries.list },
      "memory" => -> { b_chat.memory.list },
      "fork" => -> { b_chat.fork(side: true, idempotency_key: SecureRandom.uuid) },
      "children" => -> { b_chat.children },
    }
    doors.each do |door, knock|
      assert_raises(CybrosAgent::Api::NotFound, "#{door}: none is absence, never a refusal") { knock.call }
    end
    assert_raises(CybrosAgent::Realtime::SubscriptionRejectedError, "the cable subscribe is rejected like absence") do
      with_reactor { subscribe_to_transcript(id, workspace_public_id: @room, credential: @b.credential) }
    end

    a_chat = chat_for(@a.client, id)
    assert_equal id, a_chat.fetch.public_id, "the creator reads (full by derivation)"
    assert_equal "none", a_chat.fetch.access.default
    a_chat.turns.list
    a_chat.events

    shared_chat = chat_for(@shared_client, id)
    assert_equal "read", shared_chat.fetch.access.level_for(@shared.public_id), "the named Human reads"
    assert_includes listed_ids(@shared_client), id
    error = assert_raises(CybrosAgent::Api::Forbidden) do
      shared_chat.inputs.create(kind: "message", text: "may I?", idempotency_key: SecureRandom.uuid)
    end
    assert_equal "not_authorized", error.code, "read cannot post: refused by name, the row admitted to exist"

    assert_raises(CybrosAgent::Api::NotFound, "the workspace owner is nobody special (Q-A)") do
      chat_for(@steward_client, id).fetch
    end
    refute_includes listed_ids(@steward_client), id
  end

  # CASE 2b — THE BYTES FOLLOW THE ROW (staged uploads have no byte read): an attachment A posts on
  # a `none` conversation is read back by the named `read` Human and by A through the ONE bytes read
  # — and to B, whom the ACL narrows to `none`, the attachment is as absent as the row that names
  # it: 404, never a 403.
  def test_none_conceals_an_attachments_bytes_and_read_reads_them
    picture = @a.client.uploads.create_io(StringIO.new(RED_SQUARE), filename: "square.png")
    assert_equal "image/png", picture.content_type
    created = a_conversations.create(idempotency_key: SecureRandom.uuid, title: "with a picture",
      access: { default: "none", entries: [{ user_public_id: @shared.public_id, level: "read" }] })
    id = created.public_id
    posted = chat_for(@a.client, id).inputs.create(kind: "message", text: "look", attachments: [picture.public_id],
      idempotency_key: SecureRandom.uuid)
    assert_equal [picture.public_id], Array(posted.input.attachments).map(&:public_id), "the row names its picture"

    mine = StringIO.new
    assert_equal 200, @a.client.uploads.bytes(picture.public_id, mine).status
    assert_equal RED_SQUARE, mine.string.b, "the creator reads its own"
    theirs = StringIO.new
    assert_equal 200, @shared_client.uploads.bytes(picture.public_id, theirs).status
    assert_equal RED_SQUARE, theirs.string.b, "a `read` entry reads the attachment of a row it reads"
    assert_raises(CybrosAgent::Api::NotFound, "none: the attachment is as absent as the row") do
      @b.client.uploads.bytes(picture.public_id, StringIO.new)
    end
    assert_raises(CybrosAgent::Api::NotFound, "the workspace owner is nobody special (Q-A)") do
      @steward_client.uploads.bytes(picture.public_id, StringIO.new)
    end
  end

  # CASE 3 — A FORK AND A SIDE FORK INHERIT. The fork is B's — a non-creator `full` entry: B becomes
  # the child's creator, its own row is dropped, and A — the source's creator — still reads the
  # child (every principal's level on the child equals its level on the source, except the forker).
  # The side is A's. Both children answer the source's default and entries (copied at the fork
  # instant, never re-derived); the steward finds both absent; the side's DELETE reaps it at once
  # and the row — its copied entries with it — is gone through A's own read, which is the only read
  # this plane has.
  def test_a_fork_by_a_full_entry_and_a_side_fork_inherit_the_carrier_and_a_deleted_side_takes_its_rows_with_it
    created = a_conversations.create(idempotency_key: SecureRandom.uuid, title: "lineage",
      access: { default: "none", entries: [
        { user_public_id: @shared.public_id, level: "read" }, { user_public_id: @b.public_id, level: "full" },
      ] })
    id = created.public_id
    a_chat = chat_for(@a.client, id)
    reply = ask(a_chat, "!mock -- first")

    forked = chat_for(@b.client, id).fork(turn_public_id: reply.public_id, idempotency_key: SecureRandom.uuid).conversation
    assert_equal "none", forked.access.default, forked.to_h.inspect
    assert_equal [[@shared.public_id, "read"]], forked.access.entries.map { |e| [e.user_public_id, e.level] },
      "the forker is the child's creator now: its own row is dropped, every other entry is the source's"
    assert_equal forked.public_id, chat_for(@a.client, forked.public_id).fetch.public_id,
      "the source's creator reads the child B forked"
    # B is the child's creator — full by DERIVATION, which the carrier
    # never spells (no creator id rides the read, and the SDK's
    # `level_for` reads entries and the default alone): the pin is the
    # write the derivation admits.
    posted = chat_for(@b.client, forked.public_id).inputs.create(kind: "message", text: "B's child", idempotency_key: SecureRandom.uuid)
    assert_equal "message", posted.input.kind, "B is the child's creator (full by derivation, no row): it posts"

    side = a_chat.fork(side: true, idempotency_key: SecureRandom.uuid).conversation
    assert_equal "none", side.access.default, side.to_h.inspect
    assert_equal [[@shared.public_id, "read"], [@b.public_id, "full"]].sort,
      side.access.entries.map { |e| [e.user_public_id, e.level] }.sort, "a side by the creator copies the entries verbatim"
    assert_predicate side, :side?

    [forked, side].each do |child|
      assert_raises(CybrosAgent::Api::NotFound, "the owner is nobody special on a child either") do
        chat_for(@steward_client, child.public_id).fetch
      end
      assert_equal "read", chat_for(@shared_client, child.public_id).fetch.access.level_for(@shared.public_id)
    end

    assert_nil chat_for(@a.client, side.public_id).delete, "DELETE answers 204"
    assert_raises(CybrosAgent::Api::NotFound, "a deleted side is reaped at once, its entries with the row") do
      chat_for(@a.client, side.public_id).fetch
    end
    assert_equal id, a_chat.fetch.public_id, "the parent stands"
  end

  # CASE 4 — THE LATER CHANGE. A whole replacement of the carrier under
  # the Windows rule: A names B at `read` — B lists and reads (404 → 200)
  # and is refused a post by name; at `full` B posts; the feed carries ONE
  # `access_changed` per change with `by` A and `kind` agent; B at `read`
  # cannot re-cut the carrier (no self-escalation), B at `full` may narrow
  # the default (full control includes changing permissions) and A stays
  # full by derivation; the creator as an entry is refused by one name.
  def test_set_access_replaces_the_whole_carrier_under_the_windows_rule
    created = a_conversations.create(idempotency_key: SecureRandom.uuid, title: "changed",
      access: { default: "none" })
    id = created.public_id
    a_chat = chat_for(@a.client, id)
    b_chat = chat_for(@b.client, id)
    assert_raises(CybrosAgent::Api::NotFound) { b_chat.fetch }

    changed = a_chat.set_access(default: "none", entries: [{ user_public_id: @b.public_id, level: "read" }])
    assert_equal [[@b.public_id, "agent", "read"]], changed.access.entries.map { |e| [e.user_public_id, e.kind, e.level] }
    assert_includes listed_ids(@b.client), id, "the flip: B lists it now"
    assert_equal "read", b_chat.fetch.access.level_for(@b.public_id)
    error = assert_raises(CybrosAgent::Api::Forbidden) do
      b_chat.inputs.create(kind: "message", text: "not yet", idempotency_key: SecureRandom.uuid)
    end
    assert_equal "not_authorized", error.code, "read cannot post: the third level of a peer's post"
    error = assert_raises(CybrosAgent::Api::Forbidden, "no self-escalation from read") do
      b_chat.set_access(default: "none", entries: [{ user_public_id: @b.public_id, level: "full" }])
    end
    assert_equal "not_authorized", error.code

    a_chat.set_access(default: "none", entries: [{ user_public_id: @b.public_id, level: "full" }])
    posted = b_chat.inputs.create(kind: "message", text: "B may now", idempotency_key: SecureRandom.uuid)
    assert_equal "message", posted.input.kind
    facts = a_chat.events(limit: 50).items.select { |event| event.type == "access_changed" }
    assert_equal 2, facts.length, "one fact per change, none for a read: #{facts.map(&:to_h).inspect}"
    assert_equal [@a.public_id, "agent"], [facts.last.payload.fetch("by"), facts.last.payload.fetch("kind")],
      "the actor and its KIND are recorded"
    assert_equal [{ "user_public_id" => @b.public_id, "level" => "full" }], facts.last.payload.fetch("entries")

    narrowed = b_chat.set_access(default: "read", entries: [{ user_public_id: @b.public_id, level: "full" }])
    assert_equal "read", narrowed.access.default, "a full ENTRY re-cuts the carrier"
    # The default never touches the creator: A holds no row (the derivation
    # is never spelled on the carrier) and posts under the `read` default.
    assert_nil narrowed.access.entries.find { |entry| entry.user_public_id == @a.public_id }, "the creator has no row"
    assert_equal "message",
      a_chat.inputs.create(kind: "message", text: "still A's", idempotency_key: SecureRandom.uuid).input.kind,
      "the default never touches the creator: A posts under a `read` default"
    assert_equal "read", chat_for(@steward_client, id).fetch.access.level_for(@steward.public_id),
      "the steward reads under the new default"

    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      a_chat.set_access(default: "read", entries: [{ user_public_id: @a.public_id, level: "read" }])
    end
    assert_equal "principal_not_eligible", error.code, "the creator is full by derivation: a row would lie"
  end

  # CASE 6 — THROUGH EXE/RHO, in rho's DEDICATED workspace, where reads are
  # never fenced so every 404 → 200 below is the ACL's alone. `rho do
  # --restricted` opens `none` with the STEWARD at `full` (rho's entry, not
  # the kernel's: the steward reads the row and its side); B finds the
  # conversation, its loop and the loop index absent; `rho conversation
  # participants` prints the carrier; `add B read` flips the doors open
  # (conversation and loop alike); `rm B` closes them; `default read` opens
  # them for everyone. B's post is pinned in the room (cases 1, 2, 4) —
  # here it would be the dedication fence's 403, not the level's.
  def test_rho_do_restricted_and_rho_conversation_participants_flip_the_doors_in_rhos_workspace
    output, status = @daemon.cli("do", "!mock -- hello", "--model", MODEL, "--restricted", "--dir", project)
    assert_predicate status, :success?, "rho do --restricted failed:\n#{output}"
    conversation, loop_id = %w[conversation run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
    refute_includes [conversation, loop_id], nil, "rho do printed no conversation or loop id:\n#{output}"
    assert_match(/^access:\s+none \(restricted\)$/, output, "the answer prints the access line:\n#{output}")
    rho_ws = @world.rho_workspace_public_id

    steward_view = @steward_client.workspace(rho_ws).conversation(conversation).fetch
    assert_equal "none", steward_view.access.default
    assert_equal "full", steward_view.access.level_for(@steward.public_id), "the steward's entry is rho's"

    b_ws = @b.client.workspace(rho_ws)
    refute_includes b_ws.conversations.list(limit: 50).items.map(&:public_id), conversation
    assert_raises(CybrosAgent::Api::NotFound) { b_ws.conversation(conversation).fetch }
    assert_raises(CybrosAgent::Api::NotFound, "the loop is a second door onto its conversation") do
      b_ws.run(loop_id).fetch
    end
    refute_includes b_ws.runs.list(limit: 50).items.map(&:public_id), loop_id, "the loop index conceals it too"

    printed, status = @daemon.cli("conversation", "participants", conversation)
    assert_predicate status, :success?, "rho conversation participants failed:\n#{printed}"
    assert_match(/^default:\s+none$/, printed, printed)
    # The listing's columns: level, @handle, id, kind, name.
    assert_match(/^  full  @\S+  #{Regexp.escape(@steward.public_id)}  human  /, printed, printed)

    printed, status = @daemon.cli("conversation", "participants", conversation, "add", @b.public_id, "read")
    assert_predicate status, :success?, "rho conversation participants add failed:\n#{printed}"
    assert_match(/^  read  @\S+  #{Regexp.escape(@b.public_id)}  agent  /, printed, printed)
    assert_includes b_ws.conversations.list(limit: 50).items.map(&:public_id), conversation, "the 404 → 200 flip"
    assert_equal "read", b_ws.conversation(conversation).fetch.access.level_for(@b.public_id)
    assert_equal loop_id, b_ws.run(loop_id).fetch.public_id, "the loop door follows the conversation's level"
    assert_includes b_ws.runs.list(limit: 50).items.map(&:public_id), loop_id

    printed, status = @daemon.cli("conversation", "participants", conversation, "rm", @b.public_id)
    assert_predicate status, :success?, "rho conversation participants rm failed:\n#{printed}"
    assert_match(/\(no named participants\)|^default:/, printed, printed)
    refute_match(/#{Regexp.escape(@b.public_id)}/, printed, "B's row is gone")
    assert_raises(CybrosAgent::Api::NotFound, "rm closes the door again") { b_ws.conversation(conversation).fetch }
    assert_raises(CybrosAgent::Api::NotFound) { b_ws.run(loop_id).fetch }

    printed, status = @daemon.cli("conversation", "participants", conversation, "default", "read")
    assert_predicate status, :success?, "rho conversation participants default failed:\n#{printed}"
    assert_match(/^default:\s+read$/, printed, printed)
    assert_equal "read", b_ws.conversation(conversation).fetch.access.level_for(@b.public_id), "the default admits B"

    # The side of a restricted row: rho forks as the answerer; the steward's `full` entry is
    # copied, so the steward reads the side; under the `read` default B reads it too.
    await_run_status(rho_ws, loop_id, "completed")
    opened, status = @daemon.cli("side", conversation)
    assert_predicate status, :success?, "rho side failed:\n#{opened}"
    listed, status = @daemon.cli("followers", "--side")
    assert_predicate status, :success?, "rho loops --side failed:\n#{listed}"
    side_id = listed.lines.grep(/side of #{Regexp.escape(conversation)}$/).first.to_s[/\A(\S+)/, 1]
    refute_nil side_id, "no side listed for the restricted row:\n#{listed}"
    said, status = @daemon.cli("say", side_id, "what did I ask?")
    assert_predicate status, :success?, "rho say on the Side failed:\n#{said}"
    side = @steward_client.workspace(rho_ws).conversation(side_id)
    await("the restricted Side's reply") do
      side.turns.list.items.find do |turn|
        !turn.inherited && !turn.reference? && turn.kind == "direct_reply" && turn.status == "completed"
      end
    end
    side_view = side.fetch
    assert_predicate side_view, :side?
    assert_equal "full", side_view.access.level_for(@steward.public_id), "the steward reads rho's side"
    assert_equal "read", b_ws.conversation(side_id).fetch.access.level_for(@b.public_id)
  end

  private

    def a_conversations = @a.client.workspace(@room).conversations
    def chat_for(client, id) = client.workspace(@room).conversation(id)
    def listed_ids(client) = client.workspace(@room).conversations.list(limit: 50).items.map(&:public_id)

    # One `direct_reply` and its settled reply: an undeclared peer's reply
    # takes the kernel's plain chat path (no loop), so the mock answers it.
    def ask(chat, text)
      after = chat.turns.list.items.map(&:position).max || -1
      chat.inputs.create(kind: "direct_reply", model: MODEL, text: text, idempotency_key: SecureRandom.uuid)
      await("no reply settled past position #{after} on #{chat.public_id}") do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    def await_run_status(workspace_public_id, loop_id, status)
      await("the loop #{loop_id} never reached #{status}") do
        row = @steward_client.workspace(workspace_public_id).run(loop_id).fetch
        row if row.status == status
      end
    end

    def await(message)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
