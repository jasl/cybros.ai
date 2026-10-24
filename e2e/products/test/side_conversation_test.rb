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

# A Side shares the parent's settled prefix and freezes the persisted part of its current turn,
# including completed tool results and pending work, behind one reference boundary. The sealed
# request proves what the Side sees while the parent continues. Lifecycle coverage includes a plain
# and a side fork alike, a non-writer's side fork refused, DELETE = tombstone AND reap at once, the
# parent's archive taking its side with it. Then rho's verbs over it (`rho side`, `rho
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
  MUTATING = %w[write edit bash delegate_task code].freeze
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

  # Open a Side during real parent work, then reuse it under the read subset.
  # The reference snapshot stays separate from the Side's own completed reply.
  def test_rho_side_opens_beside_a_running_turn_and_resumes_under_the_read_subset
    conversation, _turn, first_loop = rho_do("!mock echo=content -- first")
    await_run_status(first_loop, "completed")
    chat = @conversations.conversation(conversation)
    settled_position = chat.turns.list.items.map(&:position).max
    said, status = @daemon.cli("say", conversation, "!mock echo=content tool_call=bash tool_args=#{sleep_arguments} -- keep working",
      "--mode", "queue")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    running = await_running_turn(chat, after: settled_position)
    running_loop = running.active_variant.run_public_id
    await_tool_running(running_loop)

    opened, status = @daemon.cli("side", conversation)
    assert_predicate status, :success?, "rho side failed:\n#{opened}"
    side_id = opened[/^side:\s+(\S+)/, 1]
    refute_nil side_id, opened
    side = @conversations.conversation(side_id)
    assert_predicate chat.fetch, :busy?, "the parent's turn had ended before Side opened"
    reference = side.turns.list.items.find(&:reference?)
    refute_nil reference, "the running parent is represented by a reference snapshot"
    assert_nil reference.active_variant.run_public_id
    after = side.turns.list.items.map(&:position).max
    said, status = @daemon.cli("say", side_id, "!mock echo=content -- what are you doing?")
    assert_predicate status, :success?, "rho say on the Side failed:\n#{said}"
    reply = await_reply(side, after: after)
    assert_includes reply.text.to_s, "first", "the Side's answer includes the inherited context"
    parent_names = tool_names(chat.turns.request(running.public_id, running.active_variant.public_id).request_options["tools"])
    side_names = tool_names(side.turns.request(reply.public_id, reply.active_variant.public_id).request_options["tools"])
    refute_empty parent_names
    assert_equal parent_names, side_names, "the default Side retains the ordinary declared tools"

    listed, status = @daemon.cli("followers", "--side")
    assert_predicate status, :success?, listed
    rows = listed.lines.grep(/side of #{Regexp.escape(conversation)}$/)
    assert_equal 1, rows.size, "one open Side per parent:\n#{listed}"
    assert_equal side_id, rows.first[/\A(\S+)/, 1]
    plain, = @daemon.cli("followers")
    refute_includes plain, side_id

    opened, status = @daemon.cli("side", conversation, "--tools", "read")
    assert_predicate status, :success?, opened
    assert_match(/^side:\s+#{Regexp.escape(side_id)} \(open\)$/, opened)
    assert_match(/^parent:\s+#{Regexp.escape(conversation)}$/, opened)
    assert_match(/^talk:\s+rho say #{Regexp.escape(side_id)}/, opened)
    after = side.turns.list.items.map(&:position).max
    said, status = @daemon.cli("say", side_id, "!mock echo=content -- and?")
    assert_predicate status, :success?, said
    reply = await_reply(side, after: after)
    sealed, status = @daemon.cli("request", side_id, reply.public_id)
    assert_predicate status, :success?, sealed
    names = tool_names(request_options_of(sealed)["tools"])
    refute_empty names
    assert_empty names & MUTATING, "the read Side received mutating tools: #{names.inspect}"
    assert_empty names - READ_ONLY_SUBSET
    entries = JSON.parse(sealed[/^entries:\n(.*)\z/m, 1])
    assert_includes entries.to_json, BOUNDARY_TEXT
    watched, status = @daemon.cli("watch", running_loop, "--timeout", "90")
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
  end

  private

    # ---- the SDK half ----

    # nil sends no `tool_names` (the whole declaration); `[]` sends no tools.
    def post(chat, text, tool_names: nil, executor_contexts: nil)
      fields = { kind: "direct_reply", model: MODEL, text: text, idempotency_key: SecureRandom.uuid }
      fields[:tool_names] = tool_names unless tool_names.nil?
      fields[:executor_contexts] = executor_contexts unless executor_contexts.nil?
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
            turn.active_variant&.run_public_id
        end
      end
    end

    def sleep_arguments = CGI.escape(JSON.generate({ "command" => "sleep #{WINDOW_SECONDS}" }))

    def run_context(loop_id) = @client.workspace(@workspace_public_id).run(loop_id)

    # The slow tool dispatched or running: r1 is sealed and the window open.
    def await_tool_running(loop_id, completed: 0)
      await("the slow tool never started on #{loop_id}", every: POLL) do
        row = run_context(loop_id).fetch
        tools = row.tasks.select { |task| task.kind == "tool_task" }
        row if tools.count { |task| task.status == "completed" } >= completed &&
          tools.any? { |task| %w[dispatched running].include?(task.status) }
      end
    end

    def await_run_status(loop_id, status)
      await("the loop #{loop_id} never reached #{status}", every: POLL) do
        row = run_context(loop_id).fetch
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
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
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
