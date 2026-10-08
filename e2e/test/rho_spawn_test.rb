require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/rho_spawn_assertions"
require "support/secret_hygiene"
require "support/steward_session"

# THE SPAWNED CONVERSATION THROUGH exe/rho: a model's `spawn` mints a CHILD conversation that
# persists — its own profile with a fresh context (a subagent) or a named peer — and the kernel
# relays the child's reply back exactly once: as an `origin: child` row through the one input door
# (kernel mail, drained FIRST, immutable to the person), or as the paired `<task_result …
# conversation=>` of a `wait: true` call. `send` posts into it (queued, or a STEER into its running
# turn), `status`/`cancel` read and stop it, and every refusal is a sentence the round reads by
# name. On rho's side: `rho watch` names the speaker under a wrapped row (`from:`), the child tree
# (`spawned`) and who resolved a park; `rho stop CHILD` cancels a conversation this daemon never
# followed through the kernel; and under THE ROOM KNOB (`RHO_WORKSPACE`) two rho homes under one
# steward share a steward-created room, so `rho do --agent @handle` and a peer spawn `agent:
# @handle` have a lawful argument.
#
# The mock provider ECHOES its joined input, so what a turn was SHOWN is
# readable off its answer and off the sealed request; the assertions are
# structure — the envelope bytes, the drain order, the refusal words, the
# ids, which home's log carries a claim — never a model's judgement (the
# paid lane `live_spawn` pins the words).
#
# ONE CEREMONY PER FILE (the `side_conversation` shape): the steward's
# session, the ROOM and home A's daemon are booted once for every case
# here — one device grant — and home B (the peer clause) once more, on
# its first use; both stop when the run ends. Every case opens its own
# conversations. Home A runs under the knob from its first boot, so the
# subagent half exercises the room too: a room is a workspace like any
# other to `spawn`, and `rho status` says which kind it adopted.
#
# THE RECOVERY of a torn spawn job (a second run finds the child minted
# and posts the missing brief once) is the kernel unit
# `nexus/test/services/agent_runs/spawn_test.rb` ("a second run finds the
# child already minted…") and is not repeated here.
class RhoSpawnTest < Minitest::Test
  include E2E::RhoSpawnAssertions

  MODEL = "dev/mock-text".freeze
  # THE KEYS: a round's fan is numbered past the round's own node
  # (`ExpandRound#next_round_number`), so the first scripted call of a
  # turn is `r2t0` and its continuation `r2`; the mock scripts one call
  # per round, so a second call is `r3t0`, a third `r4t0`. Round 1's
  # sealed request is still `r1`.
  # THE WINDOWS: a bash `sleep` on rho's runner holds a turn open (the
  # mock's own `slow=` is clamped to 0.2 s in every journey world). A
  # child's sleep must END while its parent's still runs, so the child's
  # reply lands as a PENDING row on a busy parent and the drain order can
  # be read; a parent's sleep must outlast the child's plus the terminal
  # verbs run inside the window (each `rho` call boots a bundle).
  CHILD_SLEEP = 20
  PARENT_SLEEP = 35
  # A bounded silence after a reply settled: longer than the relay's
  # kick, the sweep's floor and a mock turn's whole life.
  SILENCE_SECONDS = 6
  # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
  # routes), and every case reads as the same steward: polls are paced.
  POLL = 1
  AWAIT_SECONDS = 120

  World = Struct.new(:daemon, :home, :project, :steward, :actor, :room_public_id, :room_name,
    :profile, :handle, :peer_daemon, :peer_home, :peer_profile, :peer_handle, keyword_init: true)

  class << self
    attr_reader :world

    # The file's one daemon, under the room: the steward opens an
    # account-wide room first (an agent's `account_wide` create is
    # refused; a room every member of the account can enter is where a
    # second agent's write standing is real), then home A boots with
    # `RHO_WORKSPACE` naming it and adopts THAT room instead of minting a
    # dedicated workspace. Stored the moment it exists so the run-end hook
    # stops it even when the boot fails halfway.
    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-spawn-e2e")
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room_name = "Spawn room #{SecureRandom.hex(3)}"
      room = steward_client.workspaces.create(
        name: room_name, access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).workspace.public_id
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

      [world.daemon, world.peer_daemon].compact.each do |daemon|
        daemon.stop
      rescue StandardError => error
        warn "Could not stop a rho daemon: #{error.class}: #{error.message}"
      end
      [world.home, world.peer_home].compact.each do |home|
        FileUtils.remove_entry(home) if File.directory?(home)
      end
    end
  end

  Minitest.after_run { RhoSpawnTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @room = @world.room_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout (home A)")
    warn_log(@daemon&.rho_log_path, "rho structured log (home A)")
    warn_log(@world&.peer_daemon&.log_path, "rho daemon stdout (home B)")
    warn_log(@world&.peer_daemon&.rho_log_path, "rho structured log (home B)")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the rho spawn E2E logs: #{error.class}: #{error.message}"
  end

  # THE DETACHED SUBAGENT. Turn 1 spawns a child (its own
  # profile, an empty context, a label) and then sleeps on the runner, so
  # the parent is busy when the child answers. The child's first request
  # carries the brief WRAPPED — a row sent from another conversation is
  # never the model's own person, whoever sent it — and its reply comes
  # back as KERNEL MAIL: an `origin: child` row stamped with the child's
  # id and its answerer, queued (never a steer), pending on the busy
  # parent, listed by `rho inputs` with its origin word and refused to
  # `rho inputs rm` by name. At the turn boundary it drains FIRST, ahead of
  # a word the person queued before it landed, as the woken turn's seed:
  # the `<task_result … conversation=>` envelope whose body is the child's
  # echo, in which the child's own `</message>` is spelled `&lt;/message>`
  # — the one escaper, so an echoed envelope can close nothing. Then `rho
  # watch`: `mailed` by the key the model saw, the speaker under it, and
  # the child tree's line.
  def test_a_detached_subagents_reply_is_kernel_result_delivery_drained_first_immutable_to_the_person_and_rho_watch_names_the_speaker
    profile, handle = rho_identity(@daemon)
    status, exit_status = @daemon.cli("status")
    assert_predicate exit_status, :success?, "rho status failed:\n#{status}"
    assert_match(/^workspace: room #{Regexp.escape(@world.room_name)} \(#{Regexp.escape(@room)}\)$/, status,
      "under the knob the daemon adopted the steward's room and says so:\n#{status}")

    conversation, _turn, loop = rho_do(script(
      [["spawn", { "prompt" => "!mock -- child hello", "label" => "helper" }], ["bash", sleep_arguments(PARENT_SLEEP)]],
      "parent done"
    ))
    chat = @conversations.conversation(conversation)
    child = await_child(chat, label: "helper")
    assert_equal "r2t0", child.parent.spawn_node_key, "the child names the call that minted it"
    assert_equal profile, child.answering_user_public_id, "a subagent is answered by rho's own profile"
    started = task_result(loop, "r2t0")
    assert_includes started,
      "Spawned conversation #{child.public_id} (label helper), answered by @#{handle}, in the background",
      "the spawn's settle names the child, its label and its answerer:\n#{started}"

    child_chat = @conversations.conversation(child.public_id)
    reply = await_reply(child_chat, after: -1)
    brief = sealed_texts(reply.active_variant.run_public_id, "r1").join("\n")
    assert_includes brief, envelope_opening(handle, profile, conversation),
      "the brief reaches the child WRAPPED — sent from another conversation, it is not the child's person:\n#{brief}"
    assert_includes brief, "child hello", brief
    assert_includes brief, "Conversation kind: child.", "the same-profile worker receives its actual execution kind"
    refute_includes brief, "{{conversation_kind}}"

    mailed = await_feed(conversation, "the child's reply was never mailed to the parent") do |items|
      items.find { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "child" }
    end
    payload = mailed.fetch("payload")
    assert_equal "r2t0", payload["task_key"], "the mail names the key the model saw"
    assert_equal child.public_id, payload["sender_conversation_public_id"], "and the child it came from"
    assert_equal({ "kind" => "agent", "handle" => handle }, payload.fetch("authored_by").slice("kind", "handle"),
      "authored by the parent loop's creator (`AgentRuns::ResultDelivery`: the kernel impersonates nobody; " \
      "the child rides the sender stamp), kind recorded: #{payload.inspect}")
    assert_equal %w[direct_reply queue pending], payload.values_at("kind", "delivery_mode", "state"),
      "a kernel-stamped queued reply, pending on the busy parent — never a steer: #{payload.inspect}"
    assert_predicate chat.fetch, :busy?, "the mail landed while the parent's own turn still ran (the case's window)"
    mail_id = payload.fetch("input_public_id")

    listed, exit_status = @daemon.cli("inputs", conversation)
    assert_predicate exit_status, :success?, "rho inputs failed:\n#{listed}"
    # The row's text is the whole envelope, so the listing's one row spans
    # lines: the head names state, id and kind, the tail the origin word.
    assert_match(/^\s+pending\s+#{Regexp.escape(mail_id)}\s+direct_reply\s+"<task_result task="r2t0"/, listed,
      "the queue lists the kernel's row:\n#{listed}")
    assert_match(%r{^</task_result>"  \[child\]$}, listed, "with its origin word after the text:\n#{listed}")
    removed, exit_status = @daemon.cli("inputs", "rm", conversation, mail_id)
    refute_predicate exit_status, :success?, "a kernel row is immutable to the person:\n#{removed}"
    assert_includes removed, "kernel_input_immutable", "refused by name:\n#{removed}"
    word = rho_say(conversation, "!mock -- what did it say?", mode: "queue")

    events = await_feed(conversation, "the mail and the queued word never opened their turns") do |items|
      items if new_turns(items, except: [loop]).length >= 2
    end
    woken, personal = new_turns(events, except: [loop])
    assert_equal mail_id, materialized(events, woken).dig("payload", "input_public_id"),
      "THE FIRST new turn is the kernel's: the child's reply drains ahead of the person's earlier word"
    assert_equal word, materialized(events, personal).dig("payload", "input_public_id"), "the SECOND is the person's"
    woken_loop = woken.dig("payload", "run_public_id")
    await_run_status(woken_loop, "completed")
    seed = sealed_texts(woken_loop, "r1").join("\n")
    assert_includes seed, %(<task_result task="r2t0" status="completed" conversation="#{child.public_id}">),
      "the woken turn's seed is the child-reply envelope, naming the call and the child:\n#{seed}"
    assert_includes seed, "child hello", "with the child's answer inside it"
    assert_includes seed, "&lt;/message>",
      "THE ESCAPER: the child echoed its wrapped brief, and its `</message>` cannot close the envelope:\n#{seed}"
    refute_includes seed, "what did it say?", "the person's word was still queued behind it"
    await_run_status(personal.dig("payload", "run_public_id"), "completed")

    watched, exit_status = @daemon.cli("watch", conversation, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate exit_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^  delivered\s+r2t0$/, watched, "rho watch prints the mail once, by the key the model saw:\n#{watched}")
    assert_match(/^    from: @#{Regexp.escape(handle)} \(agent\) #{Regexp.escape(child.public_id)}$/, watched,
      "and the speaker under it — the child's answerer and the conversation it was sent from:\n#{watched}")
    assert_match(/^  spawned\s+#{Regexp.escape(child.public_id)} \(helper, r2t0\) answered by #{Regexp.escape(profile)} — (replying|idle)$/,
      watched, "the child tree: one line per spawned conversation:\n#{watched}")
  end

  # `wait: true` AND `parent_waiting` (steps 2 and 3). The parent's id is
  # in the brief — it exists only from turn 2, so `rho do` settles a first
  # turn and `rho say` opens the one that spawns. The child's first round
  # tries to `send` to its parent and is TAUGHT instead of deadlocked: the
  # parent's continuation is parked behind the spawn's await, so the
  # refusal says to end the turn with the answer. The child's reply then
  # settles the await TRUSTED, naming the child as its resolver, and is
  # the call's PAIRED RESULT in the continuation's sealed request — the
  # `<task_result … conversation=>` bytes, delivered there and never as
  # mail. `rho watch` prints who resolved the park.
  def test_a_waited_spawns_reply_is_the_paired_result_and_a_child_sending_to_its_waiting_parent_is_taught_to_answer
    conversation, _turn, first = rho_do("!mock -- first")
    await_run_status(first, "completed")
    chat = @conversations.conversation(conversation)

    brief = script([["send", { "to" => conversation, "message" => "!mock -- child to parent" }]], "child answer")
    rho_say(conversation, script([["spawn", { "prompt" => brief, "wait" => true, "label" => "waiter" }]], "parent has it"))
    second = await_feed(conversation, "the spawning turn never started") { |items| new_turns(items, except: [first]).first }
    second_loop = second.dig("payload", "run_public_id")
    child = await_child(chat, label: "waiter")
    assert_includes task_result(second_loop, "r2t0"),
      "Spawned conversation #{child.public_id} (label waiter), answered by @#{rho_identity(@daemon).last}; waiting for its first reply"

    child_chat = @conversations.conversation(child.public_id)
    reply = await_reply(child_chat, after: -1)
    child_loop = reply.active_variant.run_public_id
    taught = task_result(child_loop, "r2t0")
    assert_includes taught, "parent_waiting: your parent is waiting for your reply; end your turn with the answer instead of sending.",
      "the child's send to its blocking parent is refused with the teaching sentence:\n#{taught}"

    done = await_run_status(second_loop, "completed")
    await = done.fetch("tasks").find { |task| task.fetch("key") == "r2t0-spawn-1" }
    refute_nil await, "the waited spawn parked a kernel-held await under the call: #{summarize(done)}"
    assert_equal "completed", await.fetch("status"), summarize(done)
    continuation = sealed_texts(second_loop, "r2").join("\n")
    assert_includes continuation, %(<task_result task="r2t0" status="completed" conversation="#{child.public_id}">),
      "THE PAIRED RESULT: the continuation's sealed request carries the child's reply as this call's result:\n#{continuation}"
    assert_includes continuation, "child answer", continuation
    refute feed(conversation).any? { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "child" },
      "a reply that settled the await is never ALSO mailed: delivered exactly once"

    watched, exit_status = @daemon.cli("watch", conversation, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate exit_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^\s+completed\s+r2t0-spawn-1\b.*resolved by conversation #{Regexp.escape(child.public_id)}$/, watched,
      "the await's line names its resolver — the child, kind recorded:\n#{watched}")
  end

  # `send`, three ways in one turn, into a child whose brief is
  # sleeping on the runner: a STEER into that running turn lands at its
  # next model boundary as a WRAPPED row in the next round's sealed
  # request; an OWN-conversation `send` is QUEUED, never refused — an
  # `agent`-origin row the person may edit and that `held` counts; a
  # `send` to a side is refused by name. The child's reply — its echo,
  # steer included — is mailed to the parent and drains FIRST, ahead of
  # the own row the model queued before it, and both arrive as the
  # envelopes their rows earn: the mail as `<task_result>` with the
  # child's `</message>` escaped, the own row as `<message …
  # conversation=>` naming the conversation it was sent from.
  def test_send_steers_a_running_child_queues_into_ones_own_conversation_and_is_refused_by_a_side
    profile, handle = rho_identity(@daemon)
    child_brief = script([["bash", sleep_arguments(CHILD_SLEEP)]], "child done")
    # The parent launch acknowledgement carries no assertion material. Keep
    # its fixed prompt out of history; the child's echo below remains intact.
    conversation, _turn, first = rho_do(script([["spawn", { "prompt" => child_brief, "label" => "slow" }]], "spawned", reply: "spawned"))
    await_run_status(first, "completed")
    chat = @conversations.conversation(conversation)
    child = await_child(chat, label: "slow")
    child_chat = @conversations.conversation(child.public_id)
    running = await_running_turn(child_chat, after: -1)
    child_loop = running.active_variant.run_public_id
    await_tool_running(child_loop)
    side = chat.fork(side: true, idempotency_key: SecureRandom.uuid).conversation.public_id

    # THE SCRIPT'S CLOCK counts every answered call in the input, turn 1's
    # `spawn` included, so turn 2's script is padded by one element that
    # is never called (the `tool_call=bash,bash` idiom of rho_conversation).
    steer = ["send", { "to" => "slow", "message" => "!mock -- steered word", "steer" => true }]
    rho_say(conversation, script([
      steer, steer,
      ["send", { "to" => conversation, "message" => "!mock -- note to self" }],
      ["send", { "to" => side, "message" => "hi side" }],
      ["bash", sleep_arguments(PARENT_SLEEP)],
    ], "sent three"))
    second = await_feed(conversation, "the sending turn never started") { |items| new_turns(items, except: [first]).first }
    second_loop = second.dig("payload", "run_public_id")
    await("the three sends never settled", every: POLL) do
      row = loop_row(second_loop)
      row if %w[r2t0 r3t0 r4t0].all? { |key| row.fetch("tasks").any? { |task| task["key"] == key && task["status"] == "completed" } }
    end
    steered = task_result(second_loop, "r2t0")
    assert_includes steered, "Sent to #{child.public_id} (steering); this joins the existing reply, " \
      "which returns to the request that opened it.",
      "a steer joins the child's existing reply without changing its return destination:\n#{steered}"
    assert_equal "Sent to #{conversation} (queued).", task_result(second_loop, "r3t0"),
      "one's own conversation is not above itself: the row queues, nothing is refused"
    assert_includes task_result(second_loop, "r4t0"),
      "side_conversation: #{side} is a side conversation; it takes no messages.", "a side is never an addressee"

    listed, exit_status = @daemon.cli("inputs", conversation)
    assert_predicate exit_status, :success?, "rho inputs failed:\n#{listed}"
    own_id = listed[/^\s+pending\s+(\S+)\s+direct_reply\s+"!mock -- note to self"\s+\[agent\]$/, 1]
    refute_nil own_id, "the own-conversation send is a pending `agent` row on the busy parent:\n#{listed}"
    assert_equal 1, chat.inputs.list.input_queue.held, "an agent-origin row counts against the person's queue (`held`)"
    edited, exit_status = @daemon.cli("inputs", "edit", conversation, own_id, "!mock -- edited note")
    assert_predicate exit_status, :success?, "an agent-origin row is the person's to rewrite:\n#{edited}"
    assert_match(/^edited:\s+#{Regexp.escape(own_id)} \(pending\)$/, edited, edited)

    reply = await_reply(child_chat, after: -1)
    assert_equal child_loop, reply.active_variant.run_public_id, "the steer landed in the SAME turn"
    next_round = sealed_texts(child_loop, "r2").join("\n")
    assert_includes next_round, envelope_opening(handle, profile, conversation),
      "THE STEER, WRAPPED: the parent's words land in the child's next round as another conversation's:\n#{next_round}"
    assert_includes next_round, "steered word", next_round

    events = await_feed(conversation, "the child's mail and the own row never opened their turns") do |items|
      items if new_turns(items, except: [first, second_loop]).length >= 2
    end
    woken, own = new_turns(events, except: [first, second_loop])
    mailed = events.find { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "child" }
    refute_nil mailed, "the child's reply was never mailed: #{events.map { |item| item["type"] }.inspect}"
    assert_equal mailed.dig("payload", "input_public_id"), materialized(events, woken).dig("payload", "input_public_id"),
      "the kernel's row drains FIRST, ahead of the agent row the model queued before it landed"
    assert_equal own_id, materialized(events, own).dig("payload", "input_public_id"), "then the model's own send"
    woken_loop = woken.dig("payload", "run_public_id")
    await_run_status(woken_loop, "completed")
    seed = sealed_texts(woken_loop, "r1").join("\n")
    assert_includes seed, %(<task_result task="r2t0" status="completed" conversation="#{child.public_id}">), seed
    assert_includes seed, "steered word", "the child's echo carries the steer it read"
    assert_includes seed, "&lt;/message>", "and its `</message>` is spelled, never closing the envelope:\n#{seed}"
    own_loop = own.dig("payload", "run_public_id")
    await_run_status(own_loop, "completed")
    own_seed = sealed_texts(own_loop, "r1").join("\n")
    assert_includes own_seed, envelope_opening(handle, profile, conversation),
      "the own row is wrapped too — sent from a conversation, even one's own:\n#{own_seed}"
    assert_includes own_seed, "edited note", "with the person's rewrite, not the model's words"
  end

  # `rho stop CHILD` AND A PERSON'S WORD IN THE CHILD. The daemon never followed the child, so `rho
  # stop` cancels it THROUGH THE KERNEL (the tree stop) and says so; the child's turn ends
  # `canceled`, and the reply the parent was owed still arrives as mail, marked canceled. Then the
  # person speaks in the child directly: that turn is theirs — the parent did not open it — so
  # nothing is relayed, pinned by a bounded silence on the parent's feed.
  def test_rho_stop_cancels_an_unfollowed_child_through_the_kernel_and_a_persons_own_word_in_the_child_is_never_relayed
    child_brief = script([["bash", sleep_arguments(CHILD_SLEEP)]], "child finished")
    conversation, _turn, first = rho_do(script([["spawn", { "prompt" => child_brief, "label" => "doomed" }]], "spawned"))
    await_run_status(first, "completed")
    chat = @conversations.conversation(conversation)
    child = await_child(chat, label: "doomed")
    child_chat = @conversations.conversation(child.public_id)
    running = await_running_turn(child_chat, after: -1)
    await_tool_running(running.active_variant.run_public_id)

    stopped, exit_status = @daemon.cli("stop", child.public_id)
    assert_predicate exit_status, :success?, "rho stop failed:\n#{stopped}"
    assert_match(/^stopped:\s+#{Regexp.escape(child.public_id)} \(conversation\)$/, stopped, stopped)
    assert_match(/^status:\s+canceling$/, stopped, stopped)
    assert_match(/^followed:\s+no — canceled through the kernel$/,
      stopped, "a conversation nobody here followed is canceled through the kernel and says so:\n#{stopped}")
    canceled = await("the child's turn never ended canceled", every: POLL) do
      child_chat.turns.list.items.find { |turn| turn.public_id == running.public_id && turn.status == "canceled" }
    end

    woken = await_feed(conversation, "the canceled reply was never mailed") { |items| new_turns(items, except: [first]).first }
    woken_loop = woken.dig("payload", "run_public_id")
    await_run_status(woken_loop, "completed")
    seed = sealed_texts(woken_loop, "r1").join("\n")
    assert_includes seed, %(<task_result task="r2t0" status="canceled" conversation="#{child.public_id}">),
      "a reply the parent was owed still reaches it, marked canceled:\n#{seed}"
    assert_equal 1, feed(conversation).count { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "child" }

    # THE PERSON'S OWN TURN IN THE CHILD, through the kernel's door as the steward (`origin:
    # person`, no sender stamp). Not `rho say`: the daemon's row for a conversation it only attached
    # carries no model and `say` would read the child's off the loop projection (the settings'
    # `default_model` first) — a different lane, not what this pin is about: the person's own words,
    # the person's own model.
    child_chat.inputs.create(kind: "direct_reply", model: MODEL, text: "!mock -- person aside", idempotency_key: SecureRandom.uuid)
    aside = await_reply(child_chat, after: canceled.position)
    assert_equal "completed", aside.status
    sleep SILENCE_SECONDS
    assert_equal 1, feed(conversation).count { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "child" },
      "only turns the parent opened are owed: the person's own exchange in the child stays there"
  end

  def test_a_root_cancel_stops_a_spawned_child_hidden_from_the_human
    brief = script([["ask", { "prompt" => "May this child continue?" }]], "child finished")
    conversation, _turn, first = rho_do(script([["spawn", { "prompt" => brief, "label" => "restricted" }]], "spawned"))
    await_run_status(first, "completed")
    chat = @conversations.conversation(conversation)
    child = await_child(chat, label: "restricted")
    child_chat = @conversations.conversation(child.public_id)
    running = await_running_turn(child_chat, after: -1)
    child_loop = running.active_variant.run_public_id
    await("the child never parked its question", every: POLL) do
      loop_row(child_loop).fetch("tasks").find { |task| task["kind"] == "await_task" && task["status"] == "awaiting_input" }
    end

    child_chat.set_access(default: "none", entries: [])
    assert_raises(CybrosAgent::Api::NotFound) { child_chat.fetch }
    assert_raises(CybrosAgent::Api::NotFound) { @client.workspace(@room).run(child_loop).fetch }
    assert_equal conversation, chat.fetch.public_id, "the Human still has access to the root"
    begin
      assert_nil chat.cancel, "root cancellation includes its child despite the child's member ACL"
    ensure
      # The cancellation request has returned before this separate access change. The answerer
      # reopens observation; changing access cannot itself stop the child's parked execution.
      printed, status = @daemon.cli("conversation", "participants", child.public_id, "default", "full")
      assert_predicate status, :success?, "the answerer could not restore access:\n#{printed}"
    end

    await_run_status(child_loop, "canceled")
    canceled = await("the child's turn never ended canceled", every: POLL) do
      child_chat.turns.list.items.find { |turn| turn.public_id == running.public_id && turn.status == "canceled" }
    end
    assert_equal child_loop, canceled.active_variant.run_public_id
    assert_equal child.public_id, child_chat.fetch.public_id, "stopping the execution preserves the reusable child"
  rescue Minitest::Assertion, StandardError
    @daemon.cli("stop", child.public_id) if child
    raise
  end

  def test_a_turn_owned_async_spawn_continues_then_synthesizes_one_report_before_final
    rho_identity(@daemon)
    brief = script([["ask", { "prompt" => "Release the original child report?" }]], "scoped-child-report")
    conversation, turn_id, parent = rho_do(script([
      ["spawn", { "prompt" => brief, "label" => "scoped", "lifetime" => "turn", "wait" => false }],
    ], "foreground finished"))
    chat = @conversations.conversation(conversation)
    child = await_child(chat, label: "scoped")
    child_chat = @conversations.conversation(child.public_id)
    running = await_running_turn(child_chat, after: -1)
    child_loop = running.active_variant.run_public_id
    ask = await("the scoped child never asked", every: POLL) do
      loop_row(child_loop).fetch("tasks").find { |task| task["status"] == "awaiting_input" }
    end
    foreground = await("the parent did not continue alongside its child", every: POLL) do
      row = loop_row(parent)
      row if row.fetch("tasks").any? { |task| task["key"] == "r2" && task["status"] == "completed" }
    end

    assert_equal "running", foreground.fetch("status")
    completion = foreground.fetch("tasks").find { |task| task["kind"] == "delegation_task" }
    assert_equal ["turn", "running"], completion.values_at("lifetime", "status")
    assert_equal "turn", ask.fetch("lifetime"), "the child's own work inherits its obligation"
    assert_equal "running", chat.turns.list.items.find { |turn| turn.public_id == turn_id }.status,
      "streamed foreground output is not final while the child is owed"

    answered, status = @daemon.cli("answer", child_loop, ask.fetch("key"), "approved")
    assert_predicate status, :success?, answered
    finished = await_run_status(parent, "completed")
    final_request = sealed_texts(parent, finished.fetch("deliverable_task_key")).join("\n")
    envelope = %(<task_result task="r2t0" status="completed" conversation="#{child.public_id}">)
    assert_equal 1, final_request.scan(envelope).length, final_request
    assert_includes final_request, "scoped-child-report"
    assert_equal 1, chat.turns.list.items.count { |turn| turn.role == "assistant" },
      "the child is synthesized within the original reply"
    refute feed(conversation).any? { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "child" }
  end

  def test_a_turn_owned_waited_spawn_consumes_its_completion_once_without_a_second_wake
    rho_identity(@daemon)
    conversation, _turn, parent = rho_do(script([
      ["spawn", { "prompt" => "!mock -- scoped-waited-report", "lifetime" => "turn", "wait" => true,
                    "label" => "scoped-waited" }],
    ], "synthesized"))
    chat = @conversations.conversation(conversation)
    child = await_child(chat, label: "scoped-waited")
    finished = await_run_status(parent, "completed")
    completion = finished.fetch("tasks").find { |task| task["kind"] == "delegation_task" }
    assert_equal ["turn", "completed"], completion.values_at("lifetime", "status")
    assert_equal "r2", finished.fetch("deliverable_task_key"), "the existing waited continuation consumes the result"
    request = sealed_texts(parent, "r2").join("\n")
    envelope = %(<task_result task="r2t0" status="completed" conversation="#{child.public_id}">)
    assert_equal 1, request.scan(envelope).length, request
    assert_includes request, "scoped-waited-report"
    assert_equal 1, chat.turns.list.items.count { |turn| turn.role == "assistant" }
    refute feed(conversation).any? { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "child" }
  end

  # A second Agent answers in the same Workspace with B explicitly selected for
  # direct work and spawn. Its bash runs on B, while its ask stays on B's
  # application inbox and the child's reply returns to A's conversation.
  def test_a_peer_answers_direct_and_spawned_work_on_its_explicitly_selected_runner
    _profile, handle = rho_identity(@daemon)
    peer, peer_profile, peer_handle = peer_home
    refute_equal handle, peer_handle, "two homes, two handles"
    peer_runner = peer.status.dig("identity", "runner_executor_public_id")
    refute_equal @daemon.status.dig("identity", "runner_executor_public_id"), peer_runner, "two different Runners"
    a_claims = @daemon.claims.length
    b_claims = peer.claims.count { |entry| entry.fetch("tool") == "bash" }

    output, exit_status = @daemon.cli("do", script([["bash", { "command" => "printf b" }]], "b answered"),
      "--model", MODEL, "--dir", @world.project, "--agent", "@#{peer_handle}", "--runner", peer_runner)
    assert_predicate exit_status, :success?, "rho do --agent failed:\n#{output}"
    assert_match(/^agent:\s+@#{Regexp.escape(peer_handle)} \(#{Regexp.escape(peer_profile)}\)$/, output,
      "the terminal prints who answers:\n#{output}")
    conversation = output[/^conversation:\s+(\S+)/, 1]
    loop = output[/^run:\s+(\S+)/, 1]
    refute_nil loop, output
    direct = @conversations.conversation(conversation).fetch
    assert_equal peer_profile, direct.answering_user_public_id
    assert_equal peer_runner, direct.default_runner&.executor_public_id
    await_run_status(loop, "completed")
    call = loop_row(loop).fetch("tasks").find { |task| task["tool_name"] == "bash" }
    assert_equal "b", task_result(loop, call.fetch("key")), "B's selected bash answered"
    assert_equal peer_runner, call.fetch("target").fetch("executor_public_id")
    assert_equal a_claims, @daemon.claims.length, "home A does not claim work selected for B"
    assert_equal b_claims + 1, peer.claims.count { |entry| entry.fetch("tool") == "bash" }, "B's Runner claimed the direct call"

    brief = script([["ask", { "prompt" => "which one?" }], ["bash", { "command" => "printf peer" }]], "peer done")
    conversation, _turn, loop = rho_do(script([["spawn", { "prompt" => brief, "agent" => "@#{peer_handle}", "label" => "peer",
                                                         "default_runner_executor_public_id" => peer_runner }]], "asked"))
    chat = @conversations.conversation(conversation)
    assert_equal @daemon.status.dig("identity", "runner_executor_public_id"), chat.fetch.default_runner&.executor_public_id
    child = await_child(chat, label: "peer")
    assert_equal peer_profile, child.answering_user_public_id, "the peer's engine answers the child"
    assert_equal peer_runner, @conversations.conversation(child.public_id).fetch.default_runner&.executor_public_id
    assert_includes task_result(loop, "r2t0"), "answered by @#{peer_handle}, in the background"

    ask = await("the peer's ask never parked on home B's inbox", every: POLL) do
      peer.control(:get, "/asks").fetch("asks").find { |row| row["kind"] == "ask" && row["prompt"] == "which one?" }
    end
    assert_empty @daemon.control(:get, "/asks").fetch("asks"), "the ask is addressed to the ANSWERER's application, not home A's"
    reported, exit_status = peer.cli("status")
    assert_predicate exit_status, :success?, "rho status on home B failed:\n#{reported}"
    assert_match(/^asks:\s+1 pending$/, reported, reported)
    answered, exit_status = peer.cli("answer", ask.fetch("run_public_id"), ask.fetch("task_key"), "that one")
    assert_predicate exit_status, :success?, "rho answer on home B failed:\n#{answered}"
    assert_match(/^answered:\s+#{Regexp.escape(ask.fetch("task_key"))}/, answered, answered)

    child_reply = await_reply(@conversations.conversation(child.public_id), after: -1)
    child_run = child_reply.active_variant.run_public_id
    call = loop_row(child_run).fetch("tasks").find { |task| task["tool_name"] == "bash" }
    assert_equal "peer", task_result(child_run, call.fetch("key"))
    assert_equal peer_runner, call.fetch("target").fetch("executor_public_id")
    assert_equal a_claims, @daemon.claims.length, "the parent's default does not replace the child's explicit selection"
    assert_equal b_claims + 2, peer.claims.count { |entry| entry.fetch("tool") == "bash" }, "both selected bash calls ran on B"

    woken = await_feed(conversation, "the peer's reply was never mailed") { |items| new_turns(items, except: [loop]).first }
    await_run_status(woken.dig("payload", "run_public_id"), "completed")
    watched, exit_status = @daemon.cli("watch", conversation, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate exit_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^  delivered\s+r2t0$/, watched, watched)
    # THE MAIL'S AUTHOR IS THE PARENT LOOP'S CREATOR (`AgentRuns::ResultDelivery`): the kernel relays its own
    # receipt and impersonates nobody, so home A's handle stands under the mail; the PEER is the
    # sender stamp (the child's id) and the child line's answerer.
    assert_match(/^    from: @#{Regexp.escape(handle)} \(agent\) #{Regexp.escape(child.public_id)}$/, watched,
      "the mail is authored by home A, the parent loop's creator, and stamped with the peer's child:\n#{watched}")
    assert_match(/^  spawned\s+#{Regexp.escape(child.public_id)} \(peer, r2t0\) answered by #{Regexp.escape(peer_profile)} — /,
      watched, watched)
  end
end
