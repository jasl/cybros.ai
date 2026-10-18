require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "shellwords"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# THE TEST OF THE DESIGN: rho is BOTH halves at once. Home B — its own `rho server` on this world,
# the `rho_spawn`/`live_spawn` PEER lane's two-home provisioning under the ROOM KNOB — is home A's
# `rho-b` row in `settings.json#acp_agents`: `command` a wrapper the lane writes (the three Bundler
# names for rho-acp's own bundle, then `exec … exe/rho-acp "$@"` — a child inheriting rho's lock
# would rewrite it), `args` `["--mode", "ask", "--model", "dev/mock-text"]`, `env` `{RHO_HOME: B}`.
# A's model delegates (`delegate_agent`, the mock's `tool_call=`), A's runner spawns B's `rho-acp`
# in its own group, and B's surface opens a CONVERSATION on B's daemon — so the kernel holds two
# conversations answered by two profiles, joined by nothing but the wire between two rho processes,
# and every line on that wire is one side's translation of the kernel's facts. The pins, one case
# each, on one world:
#
# (i) THE DELEGATION: B's conversation appears in the kernel answered by B's user (the member plane
# lists it; B's turn's `prompt_text` is the words A handed over; `rho loops` on B follows it), A's
# result carries B's reply and — through the session A's daemon lists — B's session id, which IS B's
# conversation's public id; the capture holds the initialize document B answered. (ii) THE PARK: B's
# `bash` under `ask` rests `needs_approval` on B's loop, B's surface asks A over the wire, A's FLOOR
# and the row's policy answer `allow` — never a park on A — and B's call runs and completes. (iii)
# THE CANCEL: `rho stop` on A's conversation inside the grace sends `session/cancel` to B, and B's turn ends
# `canceled` before its sleep would have; the child and its row stay.
#
# The mock provider on both homes: A's script is one `delegate_agent`
# call per conversation, and the prompt it hands B is B's whole script
# (`!mock …`), so nothing is padded. The assertions are structure — the
# ids, the trailer, the capture's lines, the kernel's rows, the log's
# facts — never a model's words.
#
# ONE CEREMONY PER HOME, TWO GRANTS on the shared budget: the steward's
# session, the room, home B and home A are booted once for every case
# here; both stop when the run ends. Every case opens its own
# conversation on A, so a fresh child on B, and the cases run in any order.
class RhoAcpSymmetryTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  AGENT = "rho-b".freeze
  DESCRIPTION = "another rho, home B on this machine, driven over ACP".freeze
  RHO_ACP_ROOT = File.expand_path("../../agents/rho/rho-acp", __dir__)
  POLL = 1
  AWAIT_SECONDS = 120
  # B's bash the cancel cuts short: three holds, never its own clock.
  SLEEP_SECONDS = 3 * E2E::RhoDaemon::HOLD_SECONDS
  TRAILER = /session: (acp-[0-9a-f]{12}) · stop: (\w+) · calls: (\d+) \((\d+) refused by the floor\) · capture: (\S+)/
  # The three options B's surface offers a park, by id.
  PERMISSION_OPTION_IDS = %w[allow always reject].freeze

  World = Struct.new(:daemon, :home, :peer, :peer_home, :project, :scratch, :steward, :actor, :room_public_id,
    :runner_id, :profile, :handle, :peer_profile, :peer_handle, keyword_init: true)

  class << self
    attr_reader :world

    # The room first, then HOME B (the agent A delegates to), then HOME A
    # whose settings name B's wrapper — both under the knob, both
    # confirmed by the one steward. Stored the moment it exists so the
    # run-end hook stops it even when the boot fails halfway.
    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room = steward_client.workspaces.create(
        name: "ACP symmetry room #{SecureRandom.hex(3)}", access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).workspace.public_id
      scratch = Dir.mktmpdir("rho-acp-symmetry")
      # THE PROJECT, outside both homes (a home is a protected root, and
      # B's `session/new` refuses a cwd under one) and REALPATH'd (macOS's
      # `/var` is `/private/var` by the time rho has spelled it).
      project = File.realpath(Dir.mktmpdir("rho-acp-symmetry-project"))
      peer_home = Dir.mktmpdir("rho-acp-symmetry-b")
      home = Dir.mktmpdir("rho-acp-symmetry-a")
      write_settings!(home, wrapper: write_wrapper!(scratch, base_url), peer_home: peer_home)
      peer = E2E::RhoDaemon.new(base_url: base_url, home: peer_home, env: { "RHO_WORKSPACE" => room })
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_WORKSPACE" => room })
      @world = World.new(daemon: daemon, home: home, peer: peer, peer_home: peer_home, project: project,
        scratch: scratch, steward: steward, actor: actor, room_public_id: room)
      [peer, daemon].each do |booted|
        booted.start
        E2E::Ceremony.confirm(actor: actor, started: booted.start_ceremony, status: -> { booted.status })
        adopted = await_workspace_adopted(booted)
        raise "#{booted.home} adopted #{adopted} instead of the room #{room}" unless adopted == room
      end
      E2E.enable_dev_lane!
      E2E.hosts.start
      daemon.control(:post, "/environment", body: { root: project })
      [peer, daemon].each { |booted| await_rho_ready(booted) }
      @world.runner_id = daemon.status.dig("identity", "runner_executor_public_id") ||
        raise("a full-mode rho registers a runner row: #{daemon.status.inspect}")
      @world
    end

    # HOME A'S SETTINGS: the client extension, rho-dev for the verbs, and
    # the one row — B's wrapper, the design's args, B's home in `env`.
    def write_settings!(home, wrapper:, peer_home:)
      FileUtils.mkdir_p(home)
      File.write(File.join(home, "settings.json"), JSON.pretty_generate(E2E::RhoDaemon.dev_settings(plugins: {
        "rho.acp-client" => { "enabled" => true, "configuration" => { "agents" => {
          AGENT => {
            "command" => wrapper, "args" => ["--mode", "ask", "--model", MODEL],
            "env" => { "RHO_HOME" => peer_home }, "description" => DESCRIPTION,
          },
        } } },
      })), encoding: Encoding::UTF_8, perm: 0o600)
    end

    # THE WRAPPER: the child gets rho's SCRUBBED environment — Bundler's trail gone by name — so the
    # three names for rho-acp's own bundle are set here, with the harness's Nexus address (`RHO_*`
    # is scrubbed too; the row's `env` carries only B's home, as the design spells it), then the
    # surface with the row's args.
    def write_wrapper!(scratch, base_url)
      path = File.join(scratch, "rho-acp-b")
      File.write(path, <<~SH, encoding: Encoding::UTF_8)
        #!/bin/bash
        export BUNDLE_GEMFILE=#{Shellwords.escape(File.join(RHO_ACP_ROOT, "Gemfile"))}
        export BUNDLE_LOCKFILE=#{Shellwords.escape(File.join(RHO_ACP_ROOT, "Gemfile.lock"))}
        export BUNDLE_FROZEN=true
        export RHO_NEXUS_URL=#{Shellwords.escape(base_url)}
        exec #{Shellwords.escape(Gem.ruby)} #{Shellwords.escape(Gem.bin_path("bundler", "bundle"))} exec ruby \\
          #{Shellwords.escape(File.join(RHO_ACP_ROOT, "exe", "rho-acp"))} "$@"
      SH
      File.chmod(0o755, path)
      path
    end

    def await_workspace_adopted(daemon)
      daemon.await("the daemon never reported workspace adopted") do
        document = daemon.status
        workspace = document["workspace"]
        raise "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == "adopted" ? workspace.fetch("public_id") : nil
      end
    end

    # Both addresses announced: the runner's tools (A's `delegate_agent`
    # among them) and the agent slot.
    def await_rho_ready(daemon)
      daemon.await("rho never announced its tools") do
        runner = daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
      daemon.await_announced(address: "agent")
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      [world.daemon, world.peer].compact.each do |daemon|
        daemon.stop
      rescue StandardError => error
        warn "Could not stop a rho daemon: #{error.class}: #{error.message}"
      end
      [world.home, world.peer_home, world.project, world.scratch].compact.each do |dir|
        FileUtils.remove_entry(dir) if File.directory?(dir)
      end
    end
  end

  Minitest.after_run { RhoAcpSymmetryTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @peer = @world.peer
    @steward = @world.steward
    @room = @world.room_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout (home A)")
    warn_log(@daemon&.rho_log_path, "rho structured log (home A)")
    warn_log(@peer&.log_path, "rho daemon stdout (home B)")
    warn_log(@peer&.rho_log_path, "rho structured log (home B)")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the rho_acp_symmetry E2E logs: #{error.class}: #{error.message}"
  end

  # (i) THE DELEGATION. A's runner claims `delegate_agent`, spawns B's surface and opens a session
  # on it; B's `session/new` opens a conversation on B's daemon and its id IS the session id.
  def test_acp_symmetry_a_delegation_opens_bs_conversation_answered_by_b_and_carries_its_reply_and_session
    _profile, handle = rho_identity(@daemon)
    _peer_profile, peer_handle = rho_identity(@peer)
    refute_equal handle, peer_handle, "two homes, two handles"
    marker = "hello from home b #{SecureRandom.hex(4)}"
    prompt = "!mock reply=#{CGI.escape(marker)} -- say it"

    conversation, _turn, loop = open_turn(delegate(prompt))
    done = await_run_status(loop, "completed")
    row = delegate_row(done)
    assert_equal "completed", row.fetch("status"), summarize(done)
    assert_equal @world.runner_id, row.dig("addressed_to", "executor_public_id"), "A's runner ran the delegation: #{row.inspect}"
    output = task_output(loop, row.fetch("key"))
    assert_equal "Mock: #{marker}", output.lines.first.strip, "A's result carries B's reply:\n#{output}"
    session, stop, calls, refused, = trailer(output)
    assert_equal %w[end_turn 0 0], [stop, calls, refused]

    # B'S SESSION ID: the row A's daemon lists for the session names the
    # child's own id, and that id is B's conversation's public id.
    listed = acp_session(session)
    assert_equal [AGENT, conversation], listed.values_at("agent", "conversation"), listed.inspect
    b_conversation = listed.fetch("acp_session")
    assert_kind_of String, b_conversation
    refute_empty b_conversation
    assert_equal @world.project, listed.fetch("cwd"), "the session's cwd is A's runner root"

    # B'S CONVERSATION IN THE KERNEL: answered by B's user, listed on the
    # room, its reply turn opened by the words A handed over.
    chat = @conversations.conversation(b_conversation)
    assert_equal @world.peer_profile, chat.fetch.answering_user_public_id, "B's user answers B's conversation"
    assert_includes conversation_ids, b_conversation, "the member plane lists B's conversation"
    reply = await_reply(chat, after: -1)
    assert_equal "Mock: #{marker}", reply.text.to_s.strip, "B's reply is what A was handed back"
    assert_equal prompt, reply.active_variant.prompt_text, "B's turn was opened by A's prompt, verbatim"
    assert_equal @world.peer_profile, reply.answering_user_public_id

    # `rho loops` ON B follows it: B's daemon opened the row and follows
    # the conversation (host_type conversation on its door).
    loops, status = @peer.cli("followers")
    assert_predicate status, :success?, "rho loops on home B failed:\n#{loops}"
    assert_match(/^#{Regexp.escape(b_conversation)}  /, loops, "home B follows the conversation it opened:\n#{loops}")
    follower = @peer.control(:get, "/followers").fetch("followers").find { |candidate| candidate.fetch("public_id") == b_conversation }
    refute_nil follower, "B's daemon lists the followed conversation"
    assert_equal "conversation", follower.fetch("host_type")

    # THE CAPTURE: the initialize document B answered (the design's,
    # `agentInfo.name` rho, `authMethods` non-empty), `session/new` with
    # A's cwd and no servers answered by B's conversation id, the prompt,
    # the chunks. And A's log: the spawn and the session, named.
    lines = capture_lines(session)
    initialized = answer_to(lines, "initialize")
    assert_equal "rho", initialized.dig("agentInfo", "name"), initialized.inspect
    assert_equal 1, initialized.fetch("protocolVersion")
    refute_empty initialized.fetch("authMethods"), "B offers its auth methods"
    opened_request = request_line(lines, "session/new")
    assert_equal [@world.project, []], opened_request.dig("message", "params").values_at("cwd", "mcpServers"), "A hands B its root and no servers"
    assert_equal b_conversation, answer_to(lines, "session/new").fetch("sessionId")
    assert_equal prompt, request_line(lines, "session/prompt").dig("message", "params", "prompt", 0, "text")
    assert(lines.any? { |line| line.dig("message", "params", "update", "sessionUpdate") == "agent_message_chunk" }, "B's chunks are captured")
    await_rho_log(@daemon, /event=acp\.child_spawned agent=#{AGENT} conversation=#{Regexp.escape(conversation)} pid=\d+/, "the spawn was never logged")
    await_rho_log(@daemon, /event=acp\.session_opened agent=#{AGENT} conversation=#{Regexp.escape(conversation)} session=#{session} acp_session=#{Regexp.escape(b_conversation)}/,
      "the session was never logged with B's conversation id")
  end

  # (ii) THE PARK: B's surface runs under `ask`, so B's `bash` parks on
  # B's loop and B asks A `session/request_permission` with the three
  # options; A's floor reads the command, the row's policy allows, and
  # B's call runs — in A's project, where the file lands.
  def test_acp_symmetry_bs_park_under_ask_is_answered_by_as_floor_and_completes
    held = File.join(@world.project, "held-#{SecureRandom.hex(4)}.txt")
    command = "printf held > #{held}"

    _conversation, _turn, loop = open_turn(delegate(script([bash(command)], "ran it")))
    done = await_run_status(loop, "completed")
    row = delegate_row(done)
    assert_equal "completed", row.fetch("status"), summarize(done)
    output = task_output(loop, row.fetch("key"))
    assert_equal "Mock: ran it", output.lines.first.strip, output
    session, stop, calls, refused, = trailer(output)
    assert_equal %w[end_turn 1 0], [stop, calls, refused], "one call seen, none refused by the floor"
    assert_equal "held", File.read(held, encoding: Encoding::UTF_8), "B's approved bash ran in A's project"

    # THE ASK OVER THE WIRE, and A's answer: the request names B's call
    # (kind execute, the command as `rawInput`) with the three options;
    # A selected `allow`; the capture's note and A's log say by whom.
    lines = capture_lines(session)
    request = request_line(lines, "session/request_permission", direction: "in")
    call = request.dig("message", "params", "toolCall")
    assert_equal ["execute", { "command" => command }], call.values_at("kind", "rawInput"), call.inspect
    assert_equal PERMISSION_OPTION_IDS, request.dig("message", "params", "options").map { |option| option.fetch("optionId") }
    # The RESPONSE to B's request, not A's own request under the same id:
    # each side numbers its requests from 1, so an `out` line with B's id
    # is A's `initialize` unless it carries a `result` (the gate on
    # 3a7d9360 read nil here).
    answer = lines.find do |line|
      line["dir"] == "out" && line.dig("message", "id") == request.dig("message", "id") && line.dig("message").key?("result")
    end
    refute_nil answer, "A answered the request:\n#{lines.inspect}"
    assert_equal({ "outcome" => "selected", "optionId" => "allow" }, answer.dig("message", "result", "outcome"))
    note = lines.find { |line| line["dir"] == "note" && line["event"] == "permission" }
    refute_nil note, "the decision is a capture note"
    assert_equal %w[execute allow policy], note.values_at("kind", "decision", "by"), note.inspect
    assert_equal call.fetch("toolCallId"), note.fetch("tool_call")
    await_rho_log(@daemon, /event=acp\.permission agent=#{AGENT} kind=execute decision=allow by=policy/, "the allow was never logged")
    assert_equal 0, @daemon.control(:get, "/asks").fetch("asks").length, "nothing parked on A: the floor decided locally"

    # B'S SIDE: the parked call completed on B's loop, and B's turn with it.
    b_loop, b_key = loop_and_key(call.fetch("toolCallId"))
    task = task_detail(b_loop, b_key)
    assert_equal %w[bash completed], task.values_at("tool_name", "status"), task.inspect
    assert_equal "completed", await_loop_turn_status(b_loop, "completed").dig("turn", "status")
    settled = lines.select { |line| line.dig("message", "params", "update", "sessionUpdate") == "tool_call_update" }.last
    refute_nil settled, "B told A how the call settled"
    assert_equal "completed", settled.dig("message", "params", "update", "status"), settled.inspect
  end

  # (iii) THE CANCEL: B's bash sleeps; `rho stop` on A's conversation while it runs — the delegation's
  # cancel signal — sends `session/cancel` to B inside the grace, and B's turn is `canceled` well
  # before the sleep would have ended. The child and its row survive the cancel.
  def test_acp_symmetry_as_stop_reaches_bs_turn_as_canceled
    conversation, _turn, loop = open_turn(delegate(script([bash("sleep #{SLEEP_SECONDS}")], "slept")))
    key = await_delegate_key(loop)
    await("the delegation was never claimed") { @daemon.claimed_keys.include?(key) ? true : nil }
    session = await("the session never listed on A") do
      @daemon.control(:get, "/acp").fetch("sessions").find { |row| row["conversation"] == conversation }&.fetch("session")
    end
    b_conversation = acp_session(session).fetch("acp_session")
    tool_call_id = await("B never announced its bash to A") do
      announced = capture_lines(session).find { |line| line.dig("message", "params", "update", "sessionUpdate") == "tool_call" }
      announced&.dig("message", "params", "update", "toolCallId")
    end
    b_loop, b_key = loop_and_key(tool_call_id)
    await_task_status(b_loop, b_key, %w[dispatched running])

    started = monotonic
    stopped = rho("stop", conversation)
    assert_match(/^stopped:\s+#{Regexp.escape(conversation)} \(conversation\)$/, stopped, stopped)
    task = await("A's delegation never canceled") do
      candidate = loop_row(loop).fetch("tasks").find { |row| row.fetch("key") == key }
      candidate if candidate && candidate.fetch("status") == "canceled"
    end
    assert_equal "run_canceled", task.dig("error", "key"), task.inspect
    assert(capture_lines(session).any? { |line| line["dir"] == "out" && line.dig("message", "method") == "session/cancel" },
      "session/cancel reached B")
    await_rho_log(@daemon, /event=acp\.cancel_sent agent=#{AGENT} session=#{session}/, "the cancel was never logged")

    assert_equal "canceled", await_loop_turn_status(b_loop, "canceled").dig("turn", "status"), "B's turn ends canceled"
    assert_operator monotonic - started, :<, SLEEP_SECONDS, "the cancel ended B's hold, not its clock"
    canceled = await("B's conversation never showed the canceled turn") do
      @conversations.conversation(b_conversation).turns.list.items.find { |turn| turn.role == "assistant" && turn.status == "canceled" }
    end
    # B's profile read here, not off the world: the cases run in any order.
    assert_equal rho_identity(@peer).first, canceled.answering_user_public_id, "B's user answers the canceled turn"
    assert_equal "canceled", await_loop_turn_status(loop, "canceled").dig("turn", "status"), "A's turn is canceled too"
    listed = acp_session(session)
    refute_nil listed, "a cancelled call keeps the child and its row"
    assert alive?(listed.fetch("pid")), "the child survived the cancel"
  end

  private

    # ---- the mock's scripts ----

    # A's one call: `delegate_agent` to B with B's whole script as the prompt.
    def delegate(prompt)
      "!mock tool_call=delegate_agent:#{CGI.escape(JSON.generate("agent" => AGENT, "prompt" => prompt))} -- delegated"
    end

    # B's script: one call per round, then the remainder SPOKEN (`reply=`)
    # so the echo never carries the history.
    def script(calls, remainder)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      "!mock tool_call=#{spelled.join(",")} reply=#{CGI.escape(remainder)} -- #{remainder}"
    end

    def bash(command) = ["bash", { "command" => command }]

    # ---- home A's verbs ----

    def rho(*args)
      output, status = @daemon.cli(*args)
      assert_predicate status, :success?, "rho #{args.first} failed:\n#{output}"
      output
    end

    def open_turn(prompt)
      output = rho("do", prompt, "--model", MODEL, "--dir", @world.project)
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # A home's profile and handle as `rho status` prints them, once its
    # profile is declared (the engine a conversation needs before its
    # first head); remembered per home.
    def rho_identity(daemon)
      cached = daemon.equal?(@daemon) ? [@world.profile, @world.handle] : [@world.peer_profile, @world.peer_handle]
      return cached if cached.first

      daemon.await("rho never declared its profile") { daemon.log_lines.find { |line| line["event"] == "profile.declared" } }
      printed, status = daemon.cli("status")
      assert_predicate status, :success?, "rho status failed:\n#{printed}"
      ids = [printed[/^profile:\s+(\S+)/, 1], printed[/^handle:\s+@(\S+)/, 1]]
      refute_includes ids, nil, "rho status printed no profile or handle line:\n#{printed}"
      if daemon.equal?(@daemon)
        @world.profile, @world.handle = ids
      else
        @world.peer_profile, @world.peer_handle = ids
      end
      ids
    end

    # ---- A's client table and capture ----

    def acp_session(session)
      @daemon.control(:get, "/acp").fetch("sessions").find { |row| row["session"] == session }
    end

    # The capture, as `rho acp-agents logs` prints it: one JSON object a line.
    def capture_lines(session)
      rho("acp-agents", "logs", session).lines.map { |line| JSON.parse(line) }
    end

    def request_line(lines, method, direction: "out")
      found = lines.find { |line| line["dir"] == direction && line.dig("message", "method") == method }
      refute_nil found, "no #{direction} #{method} in the capture:\n#{lines.inspect}"
      found
    end

    # The result answering the request A sent for `method`.
    def answer_to(lines, method)
      id = request_line(lines, method).dig("message", "id")
      found = lines.find { |line| line["dir"] == "in" && line.dig("message", "id") == id && line["message"].key?("result") }
      refute_nil found, "no answer to #{method} (id #{id}) in the capture:\n#{lines.inspect}"
      found.dig("message", "result")
    end

    def trailer(output)
      match = output.match(TRAILER)
      refute_nil match, "no trailer line:\n#{output}"
      match.captures
    end

    def delegate_row(done)
      row = done.fetch("tasks").find { |task| task["tool_name"] == "delegate_agent" }
      refute_nil row, summarize(done)
      row
    end

    def await_delegate_key(loop)
      await("the delegation never appeared on the loop") do
        loop_row(loop).fetch("tasks").find { |task| task["tool_name"] == "delegate_agent" }&.fetch("key")
      end
    end

    # "<loop>:<key>" — the loop and the task key B's tool call names.
    def loop_and_key(tool_call_id)
      loop_id, _separator, key = tool_call_id.rpartition(":")
      refute_empty loop_id, "the toolCallId names its loop: #{tool_call_id.inspect}"
      [loop_id, key]
    end

    # ---- the kernel, as the steward reads it ----

    def conversation_ids
      ids = []
      after = nil
      loop do
        page = @conversations.list(after: after, limit: 100)
        ids.concat(page.items.map(&:public_id))
        after = page.next_after
        break if after.nil? || page.items.empty?
      end
      ids
    end

    def await_reply(chat, after:)
      await("no reply settled past position #{after} on #{chat.public_id}") do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@room}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_detail(loop, task_key)
      document = agent_api("#{loop_path(loop)}/tasks/#{task_key}")
      document.fetch("task") { flunk "the task read was refused: #{document.inspect}" }
    end

    def task_output(loop, task_key) = task_detail(loop, task_key)["output"].to_s

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def await_run_status(loop, status)
      await("the loop #{loop} never reached #{status}") do
        row = loop_row(loop)
        flunk "the loop failed: #{row["failure_reason"].inspect} #{summarize(row)}" if row["status"] == "failed" && status != "failed"
        row if row["status"] == status
      end
    end

    # The conversation turn converges asynchronously after its loop settles.
    def await_loop_turn_status(loop, status)
      await_run_status(loop, status)
      await("the turn of loop #{loop} never reached #{status}") do
        row = loop_row(loop)
        row if row.dig("turn", "status") == status
      end
    end

    def await_task_status(loop, task_key, statuses)
      await("the task #{task_key} of #{loop} never reached #{statuses.join("/")}") do
        task = loop_row(loop).fetch("tasks").find { |candidate| candidate["key"] == task_key }
        task if task && statuses.include?(task["status"])
      end
    end

    def await_rho_log(daemon, pattern, message)
      daemon.await(message) { daemon.log_text.match(pattern) }
    end

    def await(message, every: POLL)
      latest = nil
      deadline = monotonic + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if monotonic > deadline

        sleep every
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}#{task["tool_name"] ? "/#{task["tool_name"]}" : ""}" \
          "#{task["error"] ? "/#{task["error"]["key"]}" : ""})"
      end.join(" ")
    end

    def alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
