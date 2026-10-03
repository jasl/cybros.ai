require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/device_authorization_budget"
require "support/peer_program"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# THE SIDE CONVERSATION: a fork at the LIVE head from the parent's last SETTLED turn while a later
# turn runs, flagged `side`, its inherited history rendered behind ONE boundary item — the kernel's
# fact that the turns above are reference — with the parent's prefix bytes SHARED, and pinned here
# through the sealed-request read: the side's first request equals the parent's RUNNING turn's r1
# above the boundary, byte for byte. The kernel's lifecycle beside it: `side_of_side` for a plain
# and a side fork alike, a non-writer's side fork refused, DELETE = tombstone AND reap at once, the
# parent's archive taking its side with it. Then rho's verbs over it (`rho btw`, `rho side`, `rho
# say <side>` under the read subset, `rho loops --side`) and `rho inputs rm` through the shipped
# binary.
#
# The mock provider ECHOES its joined input, so a side's answer carries
# the inherited history it was shown; what is asserted is structure — the
# sealed prefix, no tool task, the parent's timeline, the ids — never the
# answer's words (the paid lane `live_side` pins the words).
#
# ONE CEREMONY PER FILE: the daemon, its RHO_HOME, the adopted workspace,
# rho's identity and the browse-only peer are booted once for every case
# here (the `live_task_mail` shape) and stopped when the run ends, so the
# file spends one device grant, not one per test — it is not a
# ONE_PER_GROUP member. Each case opens its own conversations.
class SideConversationTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  # `Conversations::ContextAssembly::ChatHistory::BOUNDARY_TEXT` — the
  # kernel's own words, quoted so a drift in them fails here.
  BOUNDARY_TEXT = "[The turns above are inherited from the parent conversation as reference. " \
    "Only the turns after this point belong to this conversation.]".freeze
  # THE RUNNING TURN'S WINDOW: the mock's `slow=` is clamped to 0.2 s in
  # every journey world, so a turn is held open the way the mail cases hold
  # theirs — its first round calls `bash` and the runner sleeps. Every read
  # inside the window (the fork, the side's turn, the two sealed requests)
  # is a few seconds; the rest of a case runs on after the window closes.
  WINDOW_SECONDS = 25
  # rho's read-only posture (`Rho::Daemon::Loops::Sides::READ_ONLY_SUBSET`)
  # and the words a side must never be sent.
  READ_ONLY_SUBSET = %w[read grep ls find read_process memory_read].freeze
  MUTATING = %w[write edit bash task compose].freeze
  # `Rho::Daemon::Loops::Sides::SIDE_DENIAL` — the one model-facing sentence
  # rho's auto-deny writes on a btw side, quoted so a drift in it fails
  # here; the kernel wraps it as the continuation's `(approval_denied) …`.
  SIDE_DENIAL = "Denied: no tool runs in this side conversation; answer from what is already in context.".freeze
  # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
  # routes), and every case reads as the same steward: polls are paced.
  POLL = 1
  AWAIT_SECONDS = 90

  World = Struct.new(:daemon, :home, :steward, :actor, :workspace_public_id, :profile, :runner, :peer,
    keyword_init: true)

  class << self
    attr_reader :world

    # The file's one daemon: connected through the steward's shared
    # browser, its workspace adopted, the dev lane open, the hosts up.
    # Stored the moment it exists so the run-end hook stops it even when
    # the boot fails halfway.
    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-side-conversation-e2e")
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home)
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
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

  Minitest.after_run { SideConversationTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@workspace_public_id).conversations
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the side conversation E2E logs: #{error.class}: #{error.message}"
  end

  # THE KERNEL, ON THE SDK. A conversation answered by rho's profile on
  # rho's runner (a loop-backed head, so the sealed request is a loop's
  # r1): two settled turns, a third whose first round calls a slow tool.
  # Inside that window the side is forked — from the SECOND turn, the last
  # settled one, while the parent is busy — and its first turn is one
  # tool-less reply. THE RULED PIN: the parent's running turn's r1 sealed
  # before the fork, k = its length less the trailing seed; the side's r1
  # equals it on the first k entries, and its entry k is a user message
  # that opens with the boundary text and carries the side's question (the
  # wire merge of adjacent user segments); the running turn's words are
  # nowhere in it. The side's loop made no tool call; the parent's timeline
  # is the same ids after two side turns; a side is never forked again by
  # either door; the browse-only peer's side fork is refused as the
  # workspace's non-writer, not concealed.
  def test_a_side_fork_during_a_running_turn_shares_the_parents_prefix_and_is_never_forked_again
    chat = answered_conversation
    ask(chat, "!mock -- first")
    second = ask(chat, "!mock -- second")
    post(chat, "!mock tool_call=bash tool_args=#{sleep_arguments} -- third")
    running = await_running_turn(chat, after: second.position)
    running_loop = running.active_variant.agent_loop_public_id
    await_tool_running(running_loop)
    before = chat.turns.list.items.map(&:public_id)

    forked = chat.fork(side: true, idempotency_key: SecureRandom.uuid)
    assert_predicate forked.conversation, :side?, forked.conversation.to_h.inspect
    assert_equal second.public_id, forked.conversation.forked_from_turn_public_id,
      "the fork point is the parent's last SETTLED turn, never the running one"
    assert_predicate chat.fetch, :busy?, "the side was forked while the parent's turn ran"
    side = @conversations.conversation(forked.conversation.public_id)

    reply = ask(side, "!mock -- what is going on above?", tool_names: [])
    parent_request = chat.turns.request(running.public_id, running.active_variant.public_id)
    side_request = side.turns.request(reply.public_id, reply.active_variant.public_id)
    parent_entries = parent_request.entries
    side_entries = side_request.entries
    k = parent_entries.length - 1
    assert_equal "user", parent_entries.last["role"], "the parent's r1 ends on its own seed: #{roles(parent_entries)}"
    assert_includes text_of(parent_entries.last), "Conversation kind: conversation.",
      "a direct SDK input receives the current kind beside its own seed"
    assert_equal parent_entries.first(k), side_entries.first(k),
      "THE SHARED PREFIX: the side's first request differs from the parent's running request above the boundary\n" \
      "parent: #{roles(parent_entries)}\nside:   #{roles(side_entries)}"
    boundary = side_entries[k]
    refute_nil boundary, "the side's request has no entry past the shared prefix: #{roles(side_entries)}"
    assert_equal "user", boundary["role"], "the boundary rides in USER role (the Anthropic wire hoists system entries)"
    boundary_text = text_of(boundary)
    assert boundary_text.start_with?(BOUNDARY_TEXT), "the boundary item opens the side's own entry:\n#{boundary_text}"
    assert_includes boundary_text, "Conversation kind: side.", "the side knows its actual kind without rewriting the prefix"
    refute_includes boundary_text, "{{conversation_kind}}"
    assert_includes boundary_text, "what is going on above?", "the side's question merges behind the boundary"
    refute_includes side_entries.to_json, "third", "the parent's RUNNING turn is not inherited"
    assert_includes side_entries.to_json, "second", "the parent's settled turns are"
    assert_empty tool_names(side_request.request_options["tools"]), "a tool_names: [] side turn is sent no tools"

    side_loop = await_loop_status(reply.active_variant.agent_loop_public_id, "completed")
    assert_empty side_loop.tasks.select { |task| task.kind == "tool_task" },
      "the side's loop made a tool call: #{side_loop.tasks.map(&:to_h).inspect}"

    ask(side, "!mock -- and?", tool_names: [])
    assert_equal before, chat.turns.list.items.map(&:public_id),
      "the parent's timeline changed under two side turns"

    error = assert_raises(CybrosAgent::Api::InvalidRequest) { side.fork(side: true, idempotency_key: SecureRandom.uuid) }
    assert_equal "side_of_side", error.code
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      side.fork(turn_public_id: second.public_id, idempotency_key: SecureRandom.uuid)
    end
    assert_equal "side_of_side", error.code, "a PLAIN fork of a side is refused too, even at a reachable turn"

    peer_chat = peer.workspace(@workspace_public_id).conversations.conversation(chat.public_id)
    error = assert_raises(CybrosAgent::Api::Forbidden) { peer_chat.fork(side: true, idempotency_key: SecureRandom.uuid) }
    assert_equal "not_authorized", error.code, "the browse-only peer is refused as a non-writer, never concealed"

    await_idle(chat)
  end

  # THE KERNEL'S LIFECYCLE. DELETE on an idle side answers 204 and the row
  # is GONE — tombstone and reap in one call, so a read is 404 at once,
  # never a 30-day bin. The working list hides sides and `?side=1` lists
  # them alone. The parent's archive reaps its open side first: the side
  # is 404 the moment the parent is archived.
  def test_delete_reaps_a_side_at_once_and_the_parents_archive_takes_its_side_with_it
    chat = answered_conversation
    ask(chat, "!mock -- first")

    side = @conversations.conversation(chat.fork(side: true, idempotency_key: SecureRandom.uuid).conversation.public_id)
    reply = ask(side, "!mock -- aside", tool_names: [])
    side_loop = agent_loop(reply.active_variant.agent_loop_public_id)
    assert_equal "completed", side_loop.fetch.status
    refute_includes @conversations.list(limit: 50).items.map(&:public_id), side.public_id, "the working list hides sides"
    assert_includes @conversations.list(side: true, limit: 50).items.map(&:public_id), side.public_id, "?side=1 lists them"

    assert_nil side.delete, "DELETE answers 204"
    assert_raises(CybrosAgent::Api::NotFound, "a deleted side is reaped at once, not binned") { side.fetch }
    assert_raises(CybrosAgent::Api::NotFound, "its engine must not reappear as a standalone loop") { side_loop.fetch }

    second = @conversations.conversation(chat.fork(side: true, idempotency_key: SecureRandom.uuid).conversation.public_id)
    assert_predicate second.fetch, :side?
    second_reply = ask(second, "!mock -- another aside", tool_names: [])
    second_loop = agent_loop(second_reply.active_variant.agent_loop_public_id)
    assert_predicate chat.archive, :archived?
    assert_raises(CybrosAgent::Api::NotFound, "the parent's archive reaps its side first") { second.fetch }
    assert_raises(CybrosAgent::Api::NotFound, "the archive cascade hides the side's engine too") { second_loop.fetch }
    assert_predicate chat.fetch, :archived?, "the parent itself is archived, not gone"
  end

  # RHO'S VERBS, THROUGH THE SHIPPED BINARY. `rho do` opens the parent and settles its first turn;
  # `rho say --mode queue` opens a second whose first round sleeps on the runner. While it runs,
  # `rho btw` answers on the parent's side — the echo of the inherited history, printed as text
  # alone — and the parent is still busy when it has. THE BTW TURN KEEPS THE PARENT'S TOOLS (the
  # tool block renders ahead of messages, so narrowing the tool set forfeits the shared
  # provider-cache prefix): its sealed request declares the same names the parent's running request
  # did — the mock reports no cached count, so the tool set is the pin — and a second `rho btw` that
  # calls `bash` is DENIED by the daemon: the call rests `failed approval_denied` with rho's side
  # sentence, the continuation reads it, the answer still prints. `rho loops --side` lists that one
  # side, hidden from the plain listing; `rho side` on the parent RESUMES it (the same id, `open`),
  # and `rho say <side>` speaks in it under rho's read subset: the sealed request names no mutating
  # tool. Last, the parent's turn is watched to its end.
  def test_rho_btw_answers_beside_a_running_turn_and_rho_side_resumes_the_same_side_under_the_read_subset
    conversation, _turn, first_loop = rho_do("!mock -- first")
    await_loop_status(first_loop, "completed")
    chat = @conversations.conversation(conversation)

    # The spine's last position BEFORE the words go out: `rho say` on an
    # idle conversation awaits the turn it opens (ACP r2 C2), so a position
    # read after it would be the running turn's own and nothing lies past it.
    settled_position = chat.turns.list.items.map(&:position).max
    said, status = @daemon.cli("say", conversation, "!mock tool_call=bash tool_args=#{sleep_arguments} -- keep working",
      "--mode", "queue")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    running = await_running_turn(chat, after: settled_position)
    running_loop = running.active_variant.agent_loop_public_id
    await_tool_running(running_loop)

    answer, status = @daemon.cli("btw", "what are you doing?", "--on", conversation)
    assert_predicate status, :success?, "rho btw failed:\n#{answer}"
    refute_empty answer.strip, "rho btw printed nothing"
    assert_includes answer, "first", "the side's answer echoes the inherited history:\n#{answer}"
    refute_match(/^(status|loop|conversation|queued):/, answer, "btw prints the answer alone:\n#{answer}")
    assert_predicate chat.fetch, :busy?, "the parent's turn had ended before btw answered"

    listed, status = @daemon.cli("loops", "--side")
    assert_predicate status, :success?, "rho loops --side failed:\n#{listed}"
    rows = listed.lines.grep(/side of #{Regexp.escape(conversation)}$/)
    assert_equal 1, rows.size, "one open side per parent:\n#{listed}"
    side_id = rows.first[/\A(\S+)/, 1]
    plain, = @daemon.cli("loops")
    refute_includes plain, side_id, "the plain listing hides the side:\n#{plain}"

    side = @conversations.conversation(side_id)
    btw_reply = side.turns.list.items.find { |turn| turn.role == "assistant" && turn.status == "completed" }
    refute_nil btw_reply, "the btw turn never settled on the side"
    parent_names = tool_names(chat.turns.request(running.public_id, running.active_variant.public_id)
      .request_options["tools"])
    btw_names = tool_names(side.turns.request(btw_reply.public_id, btw_reply.active_variant.public_id)
      .request_options["tools"])
    refute_empty parent_names, "the parent's running request declared no tools"
    assert_equal parent_names, btw_names, "the btw turn declares the PARENT's tool set, never none"

    after = side.turns.list.items.map(&:position).max
    answer, status = @daemon.cli("btw", "!mock tool_call=bash tool_args=#{echo_arguments} -- try a tool",
      "--on", conversation)
    assert_predicate status, :success?, "the second rho btw failed:\n#{answer}"
    assert_includes answer, SIDE_DENIAL, "the continuation read rho's denial and the answer echoes it:\n#{answer}"
    denied_reply = await_reply(side, after: after)
    denied_loop = await_loop_status(denied_reply.active_variant.agent_loop_public_id, "completed")
    call = denied_loop.tasks.find { |task| task.kind == "tool_task" }
    refute_nil call, "the btw turn under `ask` made no call to deny: #{denied_loop.tasks.map(&:to_h).inspect}"
    assert_equal "failed", call.status, call.to_h.inspect
    assert_equal({ "key" => "approval_denied", "detail" => SIDE_DENIAL }, call.error, "denied with the side sentence")
    assert_equal "agent", call.approval && call.approval["origin"], "rho's own decision, by its member bearer"

    opened, status = @daemon.cli("side", conversation)
    assert_predicate status, :success?, "rho side failed:\n#{opened}"
    assert_match(/^side:\s+#{Regexp.escape(side_id)} \(open\)$/, opened, "rho side resumes the SAME side:\n#{opened}")
    assert_match(/^parent:\s+#{Regexp.escape(conversation)}$/, opened, opened)
    assert_match(/^talk:\s+rho say #{Regexp.escape(side_id)}/, opened, opened)

    after = side.turns.list.items.map(&:position).max || -1
    said, status = @daemon.cli("say", side_id, "!mock -- and?")
    assert_predicate status, :success?, "rho say on the side failed:\n#{said}"
    reply = await_reply(side, after: after)
    sealed, status = @daemon.cli("request", side_id, reply.public_id)
    assert_predicate status, :success?, "rho request failed:\n#{sealed}"
    names = tool_names(request_options_of(sealed)["tools"])
    refute_empty names, "the read subset was sent no tools:\n#{sealed}"
    assert_empty names & MUTATING, "a side turn under rho's read subset was sent a mutating tool: #{names.inspect}"
    assert_empty names - READ_ONLY_SUBSET, "a name outside rho's read subset: #{names.inspect}"
    entries = JSON.parse(sealed[/^entries:\n(.*)\z/m, 1])
    assert_includes entries.to_json, BOUNDARY_TEXT, "the side's later turns keep the boundary"

    watched, status = @daemon.cli("watch", running_loop, "--timeout", "90")
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
  end

  # PRESET REFUSAL THROUGH THE BINARY. The dev lane is taken away under a settled conversation, so
  # the next `rho say` is accepted at the door and PARKED `blocked` by the drain
  # (`provider_disabled`) — `rho inputs` lists the head with the kernel's reason word. The lane
  # returns; `rho inputs rm` drops the head, the queue reads empty, and the next `rho say` drains to
  # a completed reply.
  def test_rho_inputs_rm_clears_a_head_the_kernel_blocked_and_the_next_say_drains
    conversation, _turn, loop = rho_do("!mock -- hello")
    await_loop_status(loop, "completed")
    chat = @conversations.conversation(conversation)

    E2E.operator.disable_dev_lane!
    begin
      said, status = @daemon.cli("say", conversation, "!mock -- blocked?")
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      input_id = said[/^queued:\s+(\S+)/, 1]
      refute_nil input_id, "rho say printed no input id:\n#{said}"
      listed = await("the kernel never parked the head blocked", every: POLL) do
        output, = @daemon.cli("inputs", conversation)
        output if output.match?(/^\s+blocked\s+#{Regexp.escape(input_id)}\b/)
      end
      assert_match(/^\s+blocked\s+#{Regexp.escape(input_id)}\s+direct_reply\s+"!mock -- blocked\?"\s+\(provider_disabled\)/,
        listed, "the listing carries the kernel's reason word:\n#{listed}")
    ensure
      E2E.operator.enable_dev_lane!
    end

    removed, status = @daemon.cli("inputs", "rm", conversation, input_id)
    assert_predicate status, :success?, "rho inputs rm failed:\n#{removed}"
    assert_match(/^removed:\s+#{Regexp.escape(input_id)}$/, removed, removed)
    emptied, = @daemon.cli("inputs", conversation)
    assert_match(/^\(the queue is empty\)$/, emptied, emptied)

    after = chat.turns.list.items.map(&:position).max
    said, status = @daemon.cli("say", conversation, "!mock -- again")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    reply = await_reply(chat, after: after)
    assert_includes reply.text.to_s, "again", "the next say drained to a reply: #{reply.to_h.inspect}"
  end

  private

    # ---- the SDK half ----

    # A conversation in rho's adopted workspace answered by rho's profile on rho's runner: every
    # head runs under rho's engine.
    def answered_conversation
      profile, runner = rho_identity
      created = @conversations.create(
        idempotency_key: SecureRandom.uuid, answering_user_public_id: profile, runner_executor_public_id: runner
      )
      @conversations.conversation(created.public_id)
    end

    # nil sends no `tool_names` (the whole declaration); `[]` sends no tools.
    def post(chat, text, tool_names: nil)
      fields = { kind: "direct_reply", model: MODEL, text: text, idempotency_key: SecureRandom.uuid }
      fields[:tool_names] = tool_names unless tool_names.nil?
      chat.inputs.create(**fields)
    end

    # One `direct_reply` and its settled reply (rho_conversation's shape).
    def ask(chat, text, tool_names: nil)
      after = chat.turns.list.items.map(&:position).max || -1
      post(chat, text, tool_names: tool_names)
      await_reply(chat, after: after)
    end

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
            turn.active_variant&.agent_loop_public_id
        end
      end
    end

    def await_idle(chat)
      await("the parent never went idle", every: POLL) { chat.fetch.busy? ? nil : true }
    end

    def sleep_arguments = CGI.escape(JSON.generate({ "command" => "sleep #{WINDOW_SECONDS}" }))

    # A harmless call for the btw turn to make and rho to deny.
    def echo_arguments = CGI.escape(JSON.generate({ "command" => "echo denied" }))

    def agent_loop(loop_id) = @client.workspace(@workspace_public_id).agent_loop(loop_id)

    # The slow tool dispatched or running: r1 is sealed and the window open.
    def await_tool_running(loop_id)
      await("the slow tool never started on #{loop_id}", every: POLL) do
        row = agent_loop(loop_id).fetch
        row if row.tasks.any? { |task| task.kind == "tool_task" && %w[dispatched running].include?(task.status) }
      end
    end

    def await_loop_status(loop_id, status)
      await("the loop #{loop_id} never reached #{status}", every: POLL) do
        row = agent_loop(loop_id).fetch
        row if row.status == status
      end
    end

    def text_of(entry) = Array(entry["parts"]).map { |part| part["text"].to_s }.join

    def roles(entries) = entries.map { |entry| entry["role"] || entry["type"] }.inspect

    # The wire form of the tools an invocation carried (responses: a flat
    # `name`; chat: `function.name`), as bare names.
    def tool_names(tools)
      Array(tools).map { |tool| tool["name"] || tool.dig("function", "name") }.compact
    end

    # `rho request`'s first block: the request options, pretty JSON between
    # its heading and the entries heading.
    def request_options_of(output)
      JSON.parse(output[/\Arequest_options:\n(.*?)\n\nentries:/m, 1] || flunk("rho request printed no request_options:\n#{output}"))
    end

    # ---- the rho half ----

    def rho_do(prompt)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # rho's profile and runner as `rho status` prints them, once per file.
    def rho_identity
      return [@world.profile, @world.runner] if @world.profile

      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
      @daemon.await("rho never declared its profile") do
        @daemon.log_lines.find { |line| line["event"] == "profile.declared" }
      end
      printed, status = @daemon.cli("status")
      assert_predicate status, :success?, "rho status failed:\n#{printed}"
      ids = [printed[/^profile:\s+(\S+)/, 1], printed[/^runner:\s+(\S+)/, 1]]
      refute_includes ids, nil, "rho status printed no profile or runner line:\n#{printed}"
      @world.profile, @world.runner = ids
      ids
    end

    # THE BROWSE-ONLY MEMBER: a second agent program paired through the
    # steward's own session and declaring nothing. rho's adopted workspace
    # is dedicated to rho, so the peer READS it through its steward's
    # access and every write is fenced (`data_writable_by?`) — the one
    # non-writer that can see the conversation at all. Paired once per file.
    def peer
      @world.peer ||= E2E::PeerProgram.pair(base_url: @base_url, actor: @world.actor, name: "side-peer").client
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
