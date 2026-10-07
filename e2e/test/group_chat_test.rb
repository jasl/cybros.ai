require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/peer_program"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# GROUP CHAT ON THE MOCK: three principals in ONE conversation — a person, rho (A, home A under the
# room knob) and a DIFFERENTLY-declared SDK peer (B, `E2E::PeerProgram` with its own
# `declare_configuration`) — and the one column that makes it a group: every input carries its
# ADDRESSEE (`rho say --to @a`, the SDK's `to:`), the reply turn it opens carries the same answerer,
# and an agent is ADDRESSED, never woken. A's `send` into the conversation it is answering in
# reaches the conversation's default answerer — B — so "A's reply mails B" is A's own `send` row,
# drained at A's boundary (`send` names no `agent` here — r6's word for an addressee inside the
# conversation — so the row is the default answerer's, B's). Each agent reads the other as ONE
# wrapped user-side segment (`<message from=@handle kind=agent user=…>`, never its rounds) and the
# person bare — the bare set (the creator, the turn's answerer, that answerer's Human) is judged
# against the TURN's answerer: a word typed at `rho say` is rho's own row and rho created the
# conversation, the steward's SDK row is both agents' common Human, so the person is bare on every
# wire.
#
# The mock provider ECHOES its joined input, so what a turn was SHOWN is readable off its answer and
# off the sealed request; the assertions are structure — the envelope bytes, the drain order, the
# refusal words, the ids, which turn opened from which row — never a model's judgement (the paid
# lane `live_spawn` has a group-chat variant that checks the words).
#
# "B NOT WOKEN" is the two-instant `turns.list` read: while A runs, exactly one active
# `direct_reply` and it is A's, with A's send row PENDING and addressed to B; after A settles,
# exactly one new turn, B's, its `input_materialized` naming A's send row — never "B's inbox empty"
# (unfalsifiable under one steward: A's runner is eligible for B and bound first).
#
# ONE CEREMONY PER FILE (the `rho_spawn` shape): the steward's session, the ROOM, home A's daemon
# and the peer B are booted once for every case here — two device grants — and stopped when the run
# ends. B's turns call no tool, so B needs no executor: its declaration is a speaker's engine, and
# the kernel runs its rounds itself. B's one declared tool is one rho does not serve, so a
# `tool_names` list rho's tier would send with `--to @b` is refused by name against B's declaration
# — matching settings on two homes cannot accidentally satisfy this case.
class GroupChatTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  # A bash `sleep` on rho's runner holds A's turn open (the mock's own
  # `slow=` is clamped to 0.2 s in every journey world): long enough for
  # the two-instant read, a steer and a named queue, each a `rho` call
  # that boots a bundle.
  A_SLEEP = 25
  # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
  # routes), and every case reads as the same steward: polls are paced.
  POLL = 1
  AWAIT_SECONDS = 120
  PEER_TOOL = {
    "type" => "function",
    "function" => { "name" => "note", "description" => "Keep a note",
                    "parameters" => { "type" => "object", "properties" => { "text" => { "type" => "string" } } } },
  }.freeze

  World = Struct.new(:daemon, :home, :project, :steward, :steward_handle, :actor, :room_public_id, :room_name,
    :profile, :handle, :peer, :peer_handle, keyword_init: true)

  class << self
    attr_reader :world

    # The room, home A under `RHO_WORKSPACE`, then the peer: B pairs
    # through the steward's session (one more grant), declares ONE tool
    # under `bypass`, and is read back as a principal of the room — its
    # handle is what `--to` and the envelope name it by.
    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-group-chat-e2e")
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room_name = "Group room #{SecureRandom.hex(3)}"
      room = steward_client.workspaces.create(
        name: room_name, access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).public_id
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_WORKSPACE" => room })
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor,
        room_public_id: room, room_name: room_name)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      adopted = await_workspace_adopted(daemon)
      raise "home A adopted #{adopted} instead of the room #{room}" unless adopted == room

      E2E.enable_dev_lane!
      E2E.hosts.start
      @world.project = File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
      daemon.control(:post, "/environment", body: { root: @world.project })

      peer = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "group-b")
      peer.client.profile.declare_configuration(
        tool_definitions: [PEER_TOOL], approval_mode: "bypass", approval_rules: nil,
        prompt_mechanism: "default", compaction_policy: nil,
        runner_executor_public_ids: [daemon.status.fetch("identity").fetch("runner_executor_public_id")],
        runner_tool_names: []
      )
      principals = steward_client.workspace(room).principals
      @world.peer = peer
      @world.peer_handle = principals.find { |row| row.public_id == peer.public_id }&.handle ||
        raise("the peer #{peer.public_id} is not a principal of the room")
      steward_id = steward_client.profile.fetch.member.public_id
      @world.steward_handle = principals.find { |row| row.public_id == steward_id }&.handle ||
        raise("the steward #{steward_id} is not a principal of the room")
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

  Minitest.after_run { GroupChatTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @room = @world.room_public_id
    @peer = @world.peer
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout (home A)")
    warn_log(@daemon&.rho_log_path, "rho structured log (home A)")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the group chat E2E logs: #{error.class}: #{error.message}"
  end

  # THE SCRIPT, one turn each. Turn 1 is B's: the person opens the
  # conversation with `rho do --agent @b`, so B is its default answerer.
  # Turn 2 is A's: `rho say --to @a` — A `send`s into THIS conversation
  # (the row's addressee is the default, B) and sleeps; while A runs, the
  # two-instant read's first instant, and an UNNAMED steer that reaches
  # A, the running answerer. Turn 3 is B's, opened from A's send row at
  # A's boundary — the second instant — its seed A's words WRAPPED and
  # stamped, A's reply above it one wrapped segment. Turn 4 is A's again,
  # this time the STEWARD's own row through the SDK (`to:` by public id):
  # B's reply one wrapped segment with the escaper spelled inside it, A's
  # own send the call in its own rounds (its seed skipped), the person
  # bare. Then the timeline as B's own client reads it, the feed's
  # authors, and `rho watch`: `sent` with `from:`.
  #
  # WHO IS THE PERSON HERE: a word typed at `rho do`/`rho say` is posted
  # through rho's OWN credential, so its row is authored by A (origin
  # `agent`) — bare on A's turns because A answers them and bare on B's
  # because A CREATED the conversation (the bare set: the creator, the
  # answerer, the answerer's Human); the steward's SDK row is the human
  # voice, bare on both agents' turns as their common steward.
  def test_a_to_addresses_one_agent_whose_send_reaches_the_other_and_each_reads_the_other_wrapped_and_the_person_bare
    a_profile, a_handle = rho_identity
    b_profile = @peer.public_id
    b_handle = @world.peer_handle
    person = @world.steward_handle

    output, status = @daemon.cli("do", "!mock -- b, you are the reviewer here", "--model", MODEL,
      "--dir", @world.project, "--agent", "@#{b_handle}")
    assert_predicate status, :success?, "rho do --agent failed:\n#{output}"
    assert_match(/^agent:\s+@#{Regexp.escape(b_handle)} \(#{Regexp.escape(b_profile)}\)$/, output, output)
    conversation = output[/^conversation:\s+(\S+)/, 1]
    loop_one = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_one, output
    chat = @conversations.conversation(conversation)
    assert_equal b_profile, chat.fetch.answering_user_public_id, "B is the conversation's default answerer"
    first = await_reply(chat, after: -1)
    assert_equal b_profile, first.answering_user_public_id, "turn 1 is B's"
    assert_equal [b_profile, "agent", b_handle], [first.speaker.user_public_id, first.speaker.kind, first.speaker.handle],
      "an assistant turn's speaker is its answerer"
    b_first = sealed_texts(loop_one, "r1").join("\n")
    assert_includes b_first, "!mock -- b, you are the reviewer here"
    refute_match(/<message [^>]*>\n!mock -- b, you are the reviewer here/, b_first,
      "the opening word is bare on B's turn: posted by the conversation's creator (rho's credential)")

    # TURN 2 — A's. The send's `to` is this conversation: the row queues
    # (an own-conversation send is never refused) addressed to the default.
    send = ["send", { "to" => conversation, "message" => "!mock -- b, your view on calc.rb?" }]
    said = rho_say(conversation, script([send, ["bash", sleep_arguments(A_SLEEP)]], "asked b"), to: a_handle)
    assert_match(/^to:\s+@#{Regexp.escape(a_handle)} \(#{Regexp.escape(a_profile)}\)$/, said,
      "the terminal prints whom the turn was addressed to:\n#{said}")
    running = await_running_turn(chat, after: first.position)
    loop_two = running.active_variant.run_public_id
    assert_equal a_profile, running.answering_user_public_id, "turn 2 is A's: the addressee, not the default"
    await_task_status(loop_two, "r2t0", "completed")
    assert_equal "Sent to #{conversation} (queued).", task_result(loop_two, "r2t0"),
      "A's send into the conversation it answers in: queued, never refused"
    await_tool_running(loop_two, "bash")

    # INSTANT ONE: exactly one active reply, A's; the send row pending and
    # addressed to B; nothing of B's past its own turn 1.
    active = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "running" }
    assert_equal [a_profile], active.map(&:answering_user_public_id), "one active reply while A runs, and it is A's"
    queued = chat.inputs.list.items
    send_row = queued.find { |row| row.sender_conversation_public_id == conversation }
    refute_nil send_row, "A's send is a pending row stamped with this conversation: #{queued.map(&:to_h).inspect}"
    assert_equal %w[pending agent], [send_row.state, send_row.origin]
    assert_equal b_profile, send_row.answering_user_public_id,
      "ADDRESSED to the default answerer, B — and B has no turn: addressed, never woken"
    assert_equal [a_profile, "agent"], [send_row.speaker.user_public_id, send_row.speaker.kind], "spoken by A"
    assert_equal 1, chat.turns.list.items.count { |turn| turn.role == "assistant" && turn.answering_user_public_id == b_profile },
      "B's only turn is its first"

    # AN UNNAMED STEER while A runs reaches A — the running answerer, not the conversation's
    # default; it lands in A's next round. Echo content so the peers quote messages and tool
    # results without recursively copying rho's full instructions into their answers.
    steer_text = "!mock echo=content -- and keep it short"
    steer_said, steer_status = @daemon.cli("say", conversation, steer_text)
    assert_predicate steer_status, :success?, "rho say (steer) failed:\n#{steer_said}"
    steer_id = steer_said[/^queued:\s+(\S+) \(steering\)$/, 1]
    refute_nil steer_id, "an unnamed steer binds to the running reply:\n#{steer_said}"

    await_run_status(loop_two, "completed")
    a_round_three = sealed_texts(loop_two, "r3").join("\n")
    assert_includes a_round_three, steer_text, "the steer landed in A's next round"
    refute_match(/<message [^>]*>\n#{Regexp.escape(steer_text)}/, a_round_three, "bare: A's own person's word on A's turn")

    # INSTANT TWO: exactly one new turn, B's, opened from A's send row.
    events = await_feed(conversation, "B's turn never opened from A's send") do |items|
      items if new_turns(items, except: [loop_one, loop_two]).length >= 1
    end
    woken = new_turns(events, except: [loop_one, loop_two])
    assert_equal 1, woken.length, "exactly one new turn after A settled: #{woken.inspect}"
    assert_equal send_row.public_id, materialized(events, woken.first).dig("payload", "input_public_id"),
      "its input_materialized names A's send row"
    loop_three = woken.first.dig("payload", "run_public_id")
    third = await_reply(chat, after: running.position)
    assert_equal loop_three, third.active_variant.run_public_id
    assert_equal b_profile, third.answering_user_public_id, "turn 3 is B's"
    created = events.find { |item| item["type"] == "turn_created" && item.dig("payload", "turn_public_id") == third.public_id }
    assert_equal b_profile, created&.dig("payload", "answering_user_public_id"), "turn_created carries the answerer: #{created.inspect}"
    steer_accepted = events.find { |item| item["type"] == "input_accepted" && item.dig("payload", "input_public_id") == steer_id }
    assert_equal a_profile, steer_accepted&.dig("payload", "answering_user_public_id"),
      "the unnamed steer was addressed to the RUNNING answerer, A: #{steer_accepted.inspect}"

    # B's WIRE: A's send row is its seed, wrapped and stamped; A's reply
    # turn is ONE wrapped user-side segment (its remainder rides only in
    # user-role entries — never A's calls or results); every other word of
    # A's — the person's, through rho — bare, because A created the room's
    # conversation. Exactly two envelopes of A's, and nothing of the steward's.
    b_third = sealed_texts(loop_three, "r1").join("\n")
    assert_includes b_third,
      %(<message from="@#{a_handle}" kind="agent" user="#{a_profile}" conversation="#{conversation}">\n) \
      "!mock -- b, your view on calc.rb?\n</message>",
      "A's send row is B's seed, WRAPPED — sent from a conversation, even this one:\n#{b_third}"
    assert_includes b_third, %(<message from="@#{a_handle}" kind="agent" user="#{a_profile}">),
      "A's REPLY (turn 2) is one wrapped segment on B's wire, no conversation= — the same conversation:\n#{b_third}"
    assert_equal 2, b_third.scan(%(<message from="@#{a_handle}")).length, "the send row and the reply: nothing else of A's is wrapped"
    assert_equal ["user"], roles_carrying(loop_three, "r1", "asked b"),
      "A's final text reaches B as a user-side segment only: never A's rounds"
    # The mock echoes what it read, so A's final text carries its own send
    # result — it reaches B only INSIDE A's wrapped segment, never as a
    # tool-result entry: A's rounds are A's working, not B's history.
    assert_equal ["user"], roles_carrying(loop_three, "r1", "Sent to #{conversation} (queued)."),
      "A's send result rides B's wire only in A's wrapped final text, never as a result entry"
    refute_match(/<message [^>]*>\n!mock tool_call=send/, b_third, "the person's turn-2 word (rho's credential, the creator) is bare on B's turn")
    refute_includes b_third, %(from="@#{person}"), "the steward has not spoken yet"

    # TURN 4 — A's again, the STEWARD's own row through the SDK: B's reply
    # one wrapped segment, with the escaper spelled inside it (B echoed its
    # wrapped seed, so its `</message>` cannot close A's envelope); A's own
    # send is the call in its own rounds and its seed is skipped; the
    # person bare — A's controlling Human.
    fourth_row = chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- so, what did b say?",
      to: a_profile, idempotency_key: SecureRandom.uuid).input
    assert_equal a_profile, fourth_row.answering_user_public_id
    assert_equal [person, "human"], [fourth_row.speaker.handle, fourth_row.speaker.kind], "the steward's own row: the third speaker"
    fourth = await_reply(chat, after: third.position)
    assert_equal a_profile, fourth.answering_user_public_id, "turn 4 is A's"
    loop_four = fourth.active_variant.run_public_id
    a_fourth = sealed_texts(loop_four, "r1").join("\n")
    assert_includes a_fourth, %(<message from="@#{b_handle}" kind="agent" user="#{b_profile}">),
      "B's reply is ONE wrapped segment on A's wire, no conversation=:\n#{a_fourth}"
    assert_includes a_fourth, "&lt;/message>", "THE ESCAPER: B's echo of its wrapped seed cannot close the envelope:\n#{a_fourth}"
    refute_includes a_fourth, %(<message from="@#{a_handle}"),
      "A never reads its own send as a message: the seed it spoke is skipped (it is the call in A's own rounds)"
    assert_includes a_fourth, "Sent to #{conversation} (queued).", "A's own rounds — its send's result — are A's history"
    refute_includes a_fourth, %(from="@#{person}"), "the steward is A's controlling Human: bare on A's turn"
    assert_includes a_fourth, "!mock -- so, what did b say?"

    # THE TIMELINE AS B READS IT (B holds full in the room): four reply
    # turns, their answerers and speakers alternating; the feed's authors —
    # rho's credential four times (origin agent), the steward once — with
    # each row's addressee, in arrival order.
    b_view = @peer.client.workspace(@room).conversations.conversation(conversation).turns.list.items
      .select { |turn| turn.role == "assistant" }
    assert_equal [b_profile, a_profile, b_profile, a_profile], b_view.map(&:answering_user_public_id)
    assert_equal [b_handle, a_handle, b_handle, a_handle], b_view.map { |turn| turn.speaker.handle }
    assert_equal %w[agent agent agent agent], b_view.map { |turn| turn.speaker.kind }
    accepted = feed(conversation).select { |item| item["type"] == "input_accepted" }.map { |item| item.fetch("payload") }
    assert_equal [[a_handle, b_profile], [a_handle, a_profile], [a_handle, b_profile], [a_handle, a_profile], [person, a_profile]],
      accepted.map { |row| [row.dig("authored_by", "handle"), row["answering_user_public_id"]] },
      "every row names its author and its addressee, in arrival order"
    assert_equal %w[agent agent agent agent human], accepted.map { |row| row.dig("authored_by", "kind") }
    assert_equal [nil, nil, conversation, nil, nil], accepted.map { |row| row["sender_conversation_public_id"] },
      "only A's send carries the sender stamp"

    watched, exit_status = @daemon.cli("watch", conversation, "--timeout", "60")
    assert_predicate exit_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^  sent\s+r2t0\n    from: @#{Regexp.escape(a_handle)} \(agent\) #{Regexp.escape(conversation)}$/, watched,
      "rho watch prints A's send once, by the key the model saw, with the speaker under it:\n#{watched}")
  end

  # A NAMED `--to` THAT DIFFERS FROM THE RUNNING ANSWERER QUEUES: with A running, `rho say --to @b`
  # is `pending` — no binding, no refusal — and B's turn opens from that row at A's boundary. The
  # SDK's `to:` is the same door word, by public id.
  def test_a_named_addressee_other_than_the_running_answerer_queues_for_its_own_turn
    a_profile, a_handle = rho_identity
    b_profile = @peer.public_id

    output, status = @daemon.cli("do", "!mock -- b first", "--model", MODEL, "--dir", @world.project,
      "--agent", "@#{@world.peer_handle}")
    assert_predicate status, :success?, "rho do --agent failed:\n#{output}"
    conversation = output[/^conversation:\s+(\S+)/, 1]
    loop_one = output[/^run:\s+(\S+)/, 1]
    chat = @conversations.conversation(conversation)
    first = await_reply(chat, after: -1)

    rho_say(conversation, script([["bash", sleep_arguments(A_SLEEP)]], "a done"), to: a_handle)
    running = await_running_turn(chat, after: first.position)
    loop_two = running.active_variant.run_public_id
    assert_equal a_profile, running.answering_user_public_id
    await_tool_running(loop_two)

    said, status = @daemon.cli("say", conversation, "!mock -- b, when a is done", "--to", "@#{@world.peer_handle}")
    assert_predicate status, :success?, "rho say --to failed:\n#{said}"
    named_id = said[/^queued:\s+(\S+) \(pending\)$/, 1]
    refute_nil named_id, "a `--to` naming someone other than the running answerer queues, no binding:\n#{said}"
    accepted = chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- b, and this by id",
      to: b_profile, delivery_mode: "steer", idempotency_key: SecureRandom.uuid)
    assert_equal "pending", accepted.input.state, "the SDK's `to:` by public id, a steer with nobody to steer: queued"
    assert_equal b_profile, accepted.input.answering_user_public_id

    await_run_status(loop_two, "completed")
    events = await_feed(conversation, "B's turns never opened") do |items|
      items if new_turns(items, except: [loop_one, loop_two]).length >= 2
    end
    opened = new_turns(events, except: [loop_one, loop_two])
    assert_equal [named_id, accepted.input.public_id],
      opened.map { |turn| materialized(events, turn).dig("payload", "input_public_id") },
      "B's turns open from the person's rows at A's boundary, in arrival order"
    opened.each do |turn|
      created = events.find { |item| item["type"] == "turn_created" && item.dig("payload", "turn_public_id") == turn.dig("payload", "turn_public_id") }
      assert_equal b_profile, created&.dig("payload", "answering_user_public_id"), created.inspect
    end
  end

  # THE TWO REFUSAL WORDS, through rho and through the SDK: a name nobody
  # answers to is `principal_unknown` (rho's daemon names the handles it
  # knows; the kernel refuses the same word), and a profile with no
  # standing here — B on a conversation opened `--restricted`, where B is
  # `none` — is the create door's `answerer_not_eligible` (never
  # `not_authorized`: that is the level's word for the POSTER).
  def test_an_unknown_addressee_and_one_without_standing_are_refused_by_name
    _a_profile, a_handle = rho_identity
    b_profile = @peer.public_id

    output, status = @daemon.cli("do", "!mock -- private", "--model", MODEL, "--dir", @world.project, "--restricted")
    assert_predicate status, :success?, "rho do --restricted failed:\n#{output}"
    conversation = output[/^conversation:\s+(\S+)/, 1]
    loop_one = output[/^run:\s+(\S+)/, 1]
    await_run_status(loop_one, "completed")
    chat = @conversations.conversation(conversation)
    assert_equal "none", chat.fetch.access.default

    said, status = @daemon.cli("say", conversation, "!mock -- anyone?", "--to", "@nobody")
    refute_predicate status, :success?, "an unknown addressee is refused:\n#{said}"
    assert_match(/no principal @nobody/, said, said)
    assert_match(/@#{Regexp.escape(a_handle)}/, said, "the refusal names the handles the listing knows:\n#{said}")
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- anyone?", to: "@nobody", idempotency_key: SecureRandom.uuid)
    end
    assert_equal "principal_unknown", error.code, "the kernel's own word, by the SDK"

    said, status = @daemon.cli("say", conversation, "!mock -- b?", "--to", "@#{@world.peer_handle}")
    refute_predicate status, :success?, "B holds `none` here — it cannot answer:\n#{said}"
    assert_match(/answerer_not_eligible/, said, said)
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- b?", to: b_profile, idempotency_key: SecureRandom.uuid)
    end
    assert_equal "answerer_not_eligible", error.code
    assert_equal 1, chat.turns.list.items.count { |turn| turn.role == "assistant" }, "nothing opened: both refusals were synchronous"
  end

  def test_a_side_after_undo_keeps_the_remaining_turns_agent_instead_of_the_default
    a_profile, = rho_identity
    created = @conversations.create(answering_user_public_id: @peer.public_id,
      idempotency_key: SecureRandom.uuid)
    chat = @conversations.conversation(created.public_id)
    chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- A's retained answer",
      to: a_profile, idempotency_key: SecureRandom.uuid)
    first = await_reply(chat, after: -1)
    await_run_status(first.active_variant.run_public_id, "completed")
    assert_equal a_profile, first.answering_user_public_id

    chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- B's undone answer",
      idempotency_key: SecureRandom.uuid)
    last = await_reply(chat, after: first.position)
    await_run_status(last.active_variant.run_public_id, "completed")
    assert_equal @peer.public_id, last.answering_user_public_id
    assert_nil chat.turns.delete(last.public_id)
    assert_equal [first.public_id], chat.turns.list.items.map(&:public_id)

    forked = chat.fork(side: true, idempotency_key: SecureRandom.uuid).conversation
    assert_equal a_profile, forked.answering_user_public_id,
      "undo left a position gap, not a reason to switch the side back to the default agent"
    assert_equal first.public_id, forked.forked_from_turn_public_id
    side = @conversations.conversation(forked.public_id)
    history = side.turns.list.items
    assert_equal 1, history.length
    inherited = history.first
    assert_predicate inherited, :inherited?
    assert_equal first.public_id, inherited.public_id
    assert_equal first.text, inherited.text

    side.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- continue on the side",
      idempotency_key: SecureRandom.uuid)
    answer = await_reply(side, after: first.position)
    assert_equal a_profile, answer.answering_user_public_id
    assert_operator answer.position, :>, last.position, "the undone position remains vacant"
  end

  private

    # ---- the mock's script ----

    # `!mock tool_call=<name>:<args>,… -- <remainder>`: one scripted call
    # per round, each with its own url-encoded arguments, then the fake
    # speaks the remainder.
    def script(calls, remainder)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      "!mock tool_call=#{spelled.join(",")} -- #{remainder}"
    end

    def sleep_arguments(seconds) = { "command" => "sleep #{seconds}" }

    # ---- the rho half ----

    def rho_say(conversation, text, to: nil, mode: nil)
      arguments = ["say", conversation, text]
      arguments += ["--to", "@#{to}"] if to
      arguments += ["--mode", mode] if mode
      said, status = @daemon.cli(*arguments)
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      refute_nil said[/^queued:\s+(\S+)/, 1], "rho say printed no input id:\n#{said}"
      said
    end

    # Home A's profile and handle as `rho status` prints them, once its
    # runner has announced and its profile is declared.
    def rho_identity
      return [@world.profile, @world.handle] if @world.profile

      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
      @daemon.await("rho never declared its profile") do
        @daemon.log_lines.find { |line| line["event"] == "profile.declared" }
      end
      printed, status = @daemon.cli("status")
      assert_predicate status, :success?, "rho status failed:\n#{printed}"
      ids = [printed[/^profile:\s+(\S+)/, 1], printed[/^handle:\s+@(\S+)/, 1]]
      refute_includes ids, nil, "rho status printed no profile or handle line:\n#{printed}"
      @world.profile, @world.handle = ids
      ids
    end

    # ---- the SDK half ----

    def await_reply(chat, after:)
      await("no reply settled past position #{after} on #{chat.public_id}", every: POLL) do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    # The assistant turn past `after` that is RUNNING with its loop minted.
    def await_running_turn(chat, after:)
      await("no running turn past position #{after} on #{chat.public_id}", every: POLL) do
        chat.turns.list.items.find do |turn|
          turn.position > after && turn.role == "assistant" && turn.status == "running" &&
            turn.active_variant&.run_public_id
        end
      end
    end

    # ---- the member plane, as the steward ----

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@room}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_result(loop, task_key)
      document = agent_api("#{loop_path(loop)}/tasks/#{task_key}")
      task = document.fetch("task") { flunk "the task read was refused: #{document.inspect}" }
      task["output"] || Array(task["content"]).map { |block| block["text"] }.compact.join
    end

    def sealed_entries(loop, task_key)
      document = agent_api("#{loop_path(loop)}/tasks/#{task_key}/request")
      entries = document.dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop} has no sealed request: #{document.inspect}"
      entries
    end

    # Every string the sealed request of a round carries, whatever the
    # wire's shape: what the model was shown, searchable as text.
    def sealed_texts(loop, task_key) = texts_of(sealed_entries(loop, task_key))

    # The roles of the entries whose text carries `text`, deduplicated —
    # an entry with no role (a call, a result) reads as nil.
    def roles_carrying(loop, task_key, text)
      sealed_entries(loop, task_key).select { |entry| texts_of(entry).any? { |value| value.include?(text) } }
        .map { |entry| entry["role"] }.uniq
    end

    def texts_of(value)
      case value
      when String then [value]
      when Array then value.flat_map { |item| texts_of(item) }
      when Hash then value.values.flat_map { |item| texts_of(item) }
      else []
      end
    end

    def await_run_status(loop, status)
      await("the loop #{loop} never reached #{status}", every: POLL) do
        row = loop_row(loop)
        row if row["status"] == status
      end
    end

    # The slow tool dispatched or running: the window is open. Named, so
    # a kernel tool settling in the same turn cannot open it early.
    def await_tool_running(loop, tool_name = nil)
      await("the slow tool never started on #{loop}", every: POLL) do
        row = loop_row(loop)
        row if row.fetch("tasks").any? do |task|
          task["kind"] == "tool_task" && %w[dispatched running].include?(task["status"]) &&
            (tool_name.nil? || task["tool_name"] == tool_name)
        end
      end
    end

    def await_task_status(loop, task_key, status)
      await("the task #{task_key} of #{loop} never reached #{status}", every: POLL) do
        row = loop_row(loop)
        row if row.fetch("tasks").any? { |task| task["key"] == task_key && task["status"] == status }
      end
    end

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{@room}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def await_feed(conversation, message)
      await(message, every: POLL) { yield(feed(conversation)) }
    end

    # Every turn the feed opened on a loop other than `except`, in feed
    # order — the drain's own order.
    def new_turns(items, except:)
      items.select do |item|
        item["type"] == "turn_status" && item.dig("payload", "status") == "running" &&
          item.dig("payload", "turn_kind") != "compaction_summary" &&
          !except.include?(item.dig("payload", "run_public_id"))
      end.sort_by { |item| item.fetch("sequence") }
    end

    # The materialization that opened a turn: the input it drained.
    def materialized(items, opened)
      items.find { |item| item["type"] == "input_materialized" && item.dig("payload", "turn_public_id") == opened.dig("payload", "turn_public_id") } ||
        flunk("no materialization named the turn #{opened.inspect}: #{items.map { |item| item["type"] }.inspect}")
    end

    def await(message, every:)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
