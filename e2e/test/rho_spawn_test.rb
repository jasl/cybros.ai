require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/rho_daemon"
require "support/rho_spawn_assertions"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"

# Real rho daemons create delegated children, route peer messages by recipient, and deliver
# each child's result to the original parent. The retained journeys cover durable delivery,
# root cancellation of hidden children, asynchronous synthesis and private Runner ownership.
# The fake provider scripts calls; public execution records and Runner effects prove them.
# Daemon homes share a steward-created workspace and are paired once per file.
class RhoSpawnTest < Minitest::Test
  include E2E::RhoSpawnAssertions

  MODEL = "dev/mock-text".freeze
  # THE KEYS: a round's fan is numbered past the round's own node
  # (`ExpandRound#next_round_number`), so the first scripted call of a
  # turn is `r2t0` and its continuation `r2`; the mock scripts one call
  # per round, so a second call is `r3t0`, a third `r4t0`. Round 1's
  # sealed request is still `r1`.
  # Keep the parent busy while its child replies and CLI observations inspect drain order.
  PARENT_SLEEP = 35
  # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
  # routes), and every case reads as the same steward: polls are paced.
  POLL = 1
  AWAIT_SECONDS = 120

  World = Struct.new(:daemon, :home, :project, :steward, :actor, :room_public_id, :room_name,
    :profile, :handle, :peer_daemon, :peer_home, :peer_profile, :peer_handle, :shared_runner, keyword_init: true)

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

    def shared_runner(base_url)
      return @world.shared_runner if @world.shared_runner

      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(
        registration_identifier: "e2e-spawn-runner", runner_display_name: "Spawn environment")
      E2E::RunnerGrant.visit_connection(actor: @world.actor, authorization: authorization)
      E2E::RunnerGrant.connect_in_browser(actor: @world.actor, authorization: authorization)
      credentials = device.await_credentials(authorization)
      home = File.join(@world.home, "shared-runner").tap { |path| FileUtils.mkdir_p(path) }
      @world.shared_runner = E2E::ExecutorProcess.new(base_url: base_url, home: home,
        credential: credentials.executor_access_token, world: @world.project, environment: @world.project)
      @world.shared_runner.start
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      [world.shared_runner, world.daemon, world.peer_daemon].compact.each do |daemon|
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
    warn_log(@world&.shared_runner&.log_path, "shared Runner")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the rho spawn E2E logs: #{error.class}: #{error.message}"
  end

  def test_private_recipients_control_peer_messages_independently_of_subagent_roles
    profile, = rho_identity(@daemon)
    _peer, peer_profile, peer_handle = peer_home
    workspace = @client.workspace(@room)
    original = workspace.messaging
    peer_room = @conversations.create(idempotency_key: SecureRandom.uuid,
      answering_user_public_id: peer_profile).public_id
    workspace.set_messaging(lock_version: original.lock_version,
      agents: [{ agent_public_id: peer_profile, mode: "private", allowed_sender_public_ids: [] }])

    refused, _turn, refused_run = rho_do(script([
      ["send", { "to" => peer_room, "message" => "Must not arrive" }],
    ], "refusals received"))
    await_run_status(refused_run, "completed")
    assert_includes task_result(refused_run, "r2t0"), "messaging_not_allowed"
    assert_empty @conversations.conversation(refused).children.items
    assert_empty @conversations.conversation(peer_room).turns.list.items

    output, status = @daemon.cli("do", script([
      ["send", { "to" => refused, "message" => "Public recipient accepts" }],
    ], "private sender finished"), "--model", MODEL, "--dir", @world.project, "--agent", "@#{peer_handle}")
    assert_predicate status, :success?, "rho do --agent failed:\n#{output}"
    reverse_run = output[/^run:\s+(\S+)/, 1]
    refute_nil reverse_run, output
    await_run_status(reverse_run, "completed")
    refute_includes task_result(reverse_run, "r2t0"), "messaging_not_allowed"
    reverse_reply = await_reply(@conversations.conversation(refused), after: 0)
    assert_includes sealed_texts(reverse_reply.active_variant.run_public_id, "r1").join("\n"),
      "Public recipient accepts", "a private sender can contact a public recipient"

    workspace.set_messaging(lock_version: workspace.messaging.lock_version, agents: [
      { agent_public_id: peer_profile, mode: "private", allowed_sender_public_ids: [profile] },
      { agent_public_id: profile, mode: "private", allowed_sender_public_ids: [] },
    ])
    _permitted, _turn, permitted_run = rho_do(script([
      ["send", { "to" => peer_room, "message" => "Allowed peer message" }],
    ], "message sent"))
    await_run_status(permitted_run, "completed")
    refute_includes task_result(permitted_run, "r2t0"), "messaging_not_allowed"
    peer_reply = await_reply(@conversations.conversation(peer_room), after: -1)
    assert_includes sealed_texts(peer_reply.active_variant.run_public_id, "r1").join("\n"), "Allowed peer message"

    output, status = @daemon.cli("do", script([
      ["send", { "to" => refused, "message" => "Reverse dispatch refused" }],
    ], "peer finished"), "--model", MODEL, "--dir", @world.project, "--agent", "@#{peer_handle}")
    assert_predicate status, :success?, "rho do --agent failed:\n#{output}"
    reverse_run = output[/^run:\s+(\S+)/, 1]
    refute_nil reverse_run, output
    await_run_status(reverse_run, "completed")
    assert_includes task_result(reverse_run, "r2t0"), "messaging_not_allowed"
  ensure
    if original
      workspace.set_messaging(lock_version: workspace.messaging.lock_version,
        agents: original.agents.map(&:to_h))
    end
  end

  # THE DETACHED SUBAGENT. Turn 1 spawns a worker under the same
  # principal with an empty context and a label, then sleeps on the runner, so
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
      [["spawn", { "role" => "worker", "prompt" => "!mock -- child hello", "label" => "helper" }], ["bash", sleep_arguments(PARENT_SLEEP)]],
      "parent done", reply: "parent done"
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
      "authored by the parent loop's creator (`Runs::ResultDelivery`: the kernel impersonates nobody; " \
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

  def test_a_root_cancel_stops_a_spawned_child_hidden_from_the_human
    brief = script([["ask", { "prompt" => "May this child continue?" }]], "child finished")
    conversation, _turn, first = rho_do(script([["spawn", { "role" => "worker", "prompt" => brief, "label" => "restricted" }]], "spawned"))
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
      ["spawn", { "role" => "worker", "prompt" => brief, "label" => "scoped", "lifetime" => "turn", "wait" => false }],
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

  # B answers this conversation, so its private Runner serves the selected call.
  def test_a_peer_conversation_uses_its_answerers_private_runner
    _, handle = rho_identity(@daemon)
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

    # Opening before the first message must use the same answerer boundary.
    # An omitted Runner leaves B's conversation unbound; an explicit B Runner
    # reaches Nexus even though A cannot discover that private executor.
    [nil, peer_runner].each do |runner|
      flags = runner ? ["--runner", runner, "--dir", @world.project] : []
      opened, exit_status = @daemon.cli("do", "--model", MODEL, "--agent", "@#{peer_handle}", *flags)
      assert_predicate exit_status, :success?, "promptless rho do --agent failed:\n#{opened}"
      id = opened[/^conversation:\s+(\S+)/, 1]
      refute_nil id, opened
      refute_match(/^(turn|run|pending):/, opened, "no input has been submitted")
      chat = @conversations.conversation(id)
      document = chat.fetch
      assert_equal peer_profile, document.answering_user_public_id
      assert_equal [runner], [document.default_runner&.executor_public_id]
      assert_empty chat.inputs.list.items
      visible = @daemon.control(:get, "/runners").fetch("runners").map { |row| row.fetch("public_id") }
      refute_includes visible, peer_runner, "A cannot discover B's private Runner while B's conversation exists"

      before = peer.claims.count { |entry| entry.fetch("tool") == "bash" }
      prompt = runner ? script([["bash", { "command" => "printf first" }]], "first words", reply: "b answered") :
        "!mock reply=b%20answered -- first words"
      said, exit_status = @daemon.cli("say", id, prompt, "--mode", "queue")
      assert_predicate exit_status, :success?, "the first rho say to B failed:\n#{said}"
      input_id, turn_id, run_id = %w[queued turn run].map { |line| said[/^#{line}:\s+(\S+)/, 1] }
      refute_includes [input_id, turn_id, run_id], nil, said
      await_run_status(run_id, "completed")
      receipt = chat.inputs.materialization(input_id)
      refute_nil receipt, "the first input has an exact materialization"
      assert_equal [turn_id, run_id], [receipt.turn_public_id, receipt.run_public_id]
      assert_equal peer_profile, chat.turns.fetch(turn_id).answering_user_public_id
      assert_equal [runner], [chat.fetch.default_runner&.executor_public_id]
      calls = loop_row(run_id).fetch("tasks").select { |task| task["tool_name"] == "bash" }
      if runner
        assert_equal 1, calls.length
        assert_equal "first", task_result(run_id, calls.first.fetch("key"))
        assert_equal peer_runner, calls.first.fetch("target").fetch("executor_public_id")
      else
        assert_empty calls, "the unbound conversation can receive a text-only first reply"
      end
      assert_equal before + (runner ? 1 : 0), peer.claims.count { |entry| entry.fetch("tool") == "bash" }
      assert_equal a_claims, @daemon.claims.length, "the first say still executes under B"
    end
  end
end
