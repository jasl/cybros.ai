require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/device_authorization_budget"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# Processes belong to their conversation, so a later turn can read or stop one started earlier. A
# dead process returns its exit and is removed; starting again creates a new ID. Archiving the
# followed conversation delivers a persisted end event that kills its remaining process and records
# the exit. Standalone-loop processes instead end with their own loop.
#
# ONE CEREMONY PER FILE (the `side_conversation` shape): one daemon, one
# RHO_HOME, one grant; each case opens its own host and reads the process
# ids it was given rather than assuming a fresh table, so the cases run in
# any order. The fake reads its `!mock` line and calls what it is told;
# what is asserted is the table — never the model's words.
class ProcessesTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  POLL = 1
  AWAIT_SECONDS = 90
  # The "server": a leader that never exits on its own, so only a kill
  # ends it — bash execs a lone final command, so the listed pid is its.
  SERVER = "sleep 300".freeze
  GONE = /exited with status 3, on its own; the entry is gone — start_process again gives a new id\. Its log: /
  # THE DEAD CALL AFTER THE CONVERSATION'S END: the exit names the end.
  ENDED = /exited with signal TERM, stopped when its conversation ended here; the entry is gone — start_process again gives a new id\. Its log: /

  World = Struct.new(:daemon, :home, :steward, :actor, :workspace_public_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-processes-e2e")
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

  Minitest.after_run { ProcessesTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @workspace = @client.workspace(@workspace_public_id)
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
    warn "Could not capture the processes E2E logs: #{error.class}: #{error.message}"
  end

  # TURN 1 starts a command that exits 3 at once — the group is dead
  # before the turn ends, the entry gone. TURN 2 (the same conversation,
  # another loop) reads it, stops it and starts the server: both dead
  # calls answer the exit and "the entry is gone", the start is a new id
  # owned by the conversation and shown with turn 2's loop. Then the
  # conversation is ARCHIVED under the daemon's follow: the kernel narrates
  # `conversation_ended` on the feed and the daemon treats it as the end —
  # the group is killed, the entry removed, the log's last line says why —
  # and TURN 3, after the unarchive, reads the exit the end wrote.
  def test_a_dead_call_says_gone_a_restart_is_a_new_id_and_the_conversations_end_kills_its_server
    conversation, _turn, loop_one = rho_do(script(["start_process", { "command" => "echo bye; exit 3" }]))
    first = await_loop_status(loop_one, "completed")
    started = tool_task(first, "start_process")
    died = task_output(loop_one, started.key)
    id = died[/\A(p\d+) \(pid \d+\) exited\b/, 1]
    refute_nil id, "turn 1's start_process did not report an exit:\n#{died}"
    assert_includes died, "exited with status 3 after"
    refute_match(/^#{id}  /, processes_listing, "a group that died has no entry")

    # Turn 2's history carries turn 1's one answer: padded past it.
    said, status = @daemon.cli("say", conversation, script(
      ["read_process", { "id" => id }], ["stop_process", { "id" => id }],
      ["start_process", { "command" => SERVER, "name" => "web" }],
      answered: 1
    ))
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    loop_two = await_next_loop(conversation, after: loop_one)
    second = await_loop_status(loop_two, "completed")

    read = task_output(loop_two, tool_task(second, "read_process").key)
    assert_match(/\A#{id} #{GONE}#{Regexp.escape(@world.home)}\S+\n\nbye\n\[rho\] #{id}: leader exited with status 3, on its own; the group ended at /, read,
      "the dead read names the exit, says the entry is gone, and carries the log's tail")
    stopped = task_output(loop_two, tool_task(second, "stop_process").key)
    assert_match(/\A#{id} #{GONE}/, stopped)
    restarted = task_output(loop_two, tool_task(second, "start_process").key)
    new_id = restarted[/\A(p\d+) \(pid \d+\) running — web/, 1]
    refute_nil new_id, "the restart is a new running id:\n#{restarted}"
    refute_equal id, new_id, "the old id never revives"

    listing = processes_listing
    line = listing[/^#{new_id}  running  pid (\d+)  owner #{Regexp.escape(conversation)}  loop #{Regexp.escape(loop_two)}  web  /, 0]
    refute_nil line, "the entry is owned by the conversation and shows the loop that started it:\n#{listing}"
    pid = listing[/^#{new_id}  running  pid (\d+)/, 1].to_i
    assert alive?(pid), "the server is running"

    # THE CONVERSATION ENDS HERE — archived through the SDK under the
    # daemon's follow. The kernel's `conversation_ended` item is the end
    # signal (the daemon's socket hears it before any poll could 404):
    # the host is forgotten, the group killed, the entry removed, the
    # log's last line says why.
    chat = @workspace.conversations.conversation(conversation)
    refute_nil chat.archive.archived_at, "archive answers the archived row"
    await("the conversation's end never emptied the table", every: POLL) do
      processes_listing.include?("(no processes)") ? true : nil
    end
    await("the server outlived its conversation", every: 0.2) { alive?(pid) ? nil : true }
    logs, status = @daemon.cli("logs", new_id)
    assert_predicate status, :success?, "rho logs failed:\n#{logs}"
    assert_match(/^#{new_id}  exited \(signal TERM\)  pid #{pid}  owner #{Regexp.escape(conversation)}/, logs,
      "the person still reads the exit the table remembers")
    assert_match(/^\[rho\] #{new_id} \(web\): leader exited with signal TERM, stopped when its conversation ended here; the group ended at /,
      logs, "the log file keeps the exit fact")

    # THE DEAD CALL AFTER THE END: unarchived, the conversation's next turn
    # — through the SDK: the daemon forgot the host, and its runner answers
    # the row all the same — reads the id it left running. The exit names
    # the conversation's end, and the entry is gone.
    refute_nil chat.unarchive, "unarchive answers the row"
    # Turn 3's history carries four answers (turn 1's one, turn 2's three).
    # `kind: direct_reply`: the door's default is a `message` turn, which
    # opens no reply.
    chat.inputs.create(kind: "direct_reply", text: script(["read_process", { "id" => new_id }], answered: 4),
      model: MODEL, idempotency_key: SecureRandom.uuid)
    loop_three = await_next_loop(conversation, after: [loop_one, loop_two])
    third = await_loop_status(loop_three, "completed")
    read = task_output(loop_three, tool_task(third, "read_process").key)
    assert_match(/\A#{new_id} \(web\) #{ENDED}/, read, "the dead call names the conversation's end")
  end

  # A STANDALONE LOOP is its own host: the server it starts is owned by
  # the loop's id, and the loop's terminal is the conversation's end here.
  def test_a_standalone_loops_server_dies_at_the_loops_terminal
    authored = @daemon.control(:post, "/loops", body: {
      prompt: script(["start_process", { "command" => SERVER, "name" => "svc" }]),
      model: MODEL, working_directory: project,
    })
    loop_id = authored.dig("loop", "public_id")
    refute_nil loop_id, "Ops's author answered #{authored.inspect}"

    row = await_loop_status(loop_id, "completed")
    started = task_output(loop_id, tool_task(row, "start_process").key)
    id = started[/\A(p\d+) \(pid \d+\) running — svc/, 1]
    refute_nil id, started
    await("the loop's terminal never ended its server", every: POLL) do
      processes_listing.match?(/^#{id}  /) ? nil : true
    end
    logs, = @daemon.cli("logs", id)
    assert_match(/^#{id}  exited \(signal TERM\)  pid \d+  owner #{Regexp.escape(loop_id)}  svc/, logs,
      "a loop the daemon could place only as itself owns by its own id")
    assert_match(/stopped when its conversation ended here/, logs)
  end

  private

    # The fake's script: one `!mock` line naming the calls in order, each
    # with its own url-encoded arguments; the remainder is the prompt.
    # THE MOCK'S ONLY CLOCK is the count of tool answers in its whole
    # input (`MockLLM::App#answers_in`), history included — a later turn
    # of the same answerer reads its earlier rounds' answers — so a script
    # on a conversation that already holds `answered` results is padded
    # to that index (the `padded` idiom of provider_override): the padding
    # entries are never reached, and the calls this turn means follow.
    def script(*calls, answered: 0)
      padded = [calls.first] * answered + calls
      encoded = padded.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      "!mock tool_call=#{encoded.join(",")} -- run what the script says"
    end

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

    def processes_listing
      output, status = @daemon.cli("processes")
      assert_predicate status, :success?, "rho processes failed:\n#{output}"
      output
    end

    def agent_loop(loop_id) = @workspace.agent_loop(loop_id)

    def tool_task(row, name)
      row.tasks.find { |task| task.kind == "tool_task" && task.tool_name == name } ||
        flunk("the mock never called #{name}: #{row.tasks.map { |t| "#{t.kind}/#{t.tool_name}/#{t.status}" }.inspect}")
    end

    def task_output(loop_id, key) = agent_loop(loop_id).task(key).output.to_s

    def await_loop_status(loop_id, status)
      await("the loop #{loop_id} never reached #{status}", every: POLL) do
        row = agent_loop(loop_id).fetch
        flunk "the loop #{loop_id} failed: #{row.failure_reason.inspect}" if row.status == "failed"
        row if row.status == status
      end
    end

    # The next reply's loop, excluding kernel summary turns and the
    # loops already seen (`after`, one id or many).
    def await_next_loop(conversation, after:)
      known = Array(after)
      chat = @workspace.conversations.conversation(conversation)
      message = -> { "no turn after #{known.join(", ")} started on #{conversation}; #{queue_state(chat)}" }
      await(message, every: POLL) do
        chat.turns.list.items.filter_map { |turn| turn.active_variant&.agent_loop_public_id if turn.kind == "direct_reply" }
          .find { |loop_id| !known.include?(loop_id) }
      end
    end

    # What the kernel holds when a turn never opens: the turns, the queue
    # and the feed's tail — read at the flunk, never before.
    def queue_state(chat)
      turns = chat.turns.list.items.map { |turn| [turn.position, turn.kind, turn.status, turn.active_variant&.agent_loop_public_id] }
      inputs = chat.inputs.list.items.map { |row| [row.public_id, row.state, row.kind, row.answering_user_public_id] }
      feed = feed_of(chat).last(12).map { |item| [item.type, item.payload.slice("input_public_id", "blocked_reason", "status")] }
      "turns #{turns.inspect}; inputs #{inputs.inspect}; feed tail #{feed.inspect}"
    rescue StandardError => error
      "queue state unreadable: #{error.class}: #{error.message}"
    end

    def feed_of(chat)
      items = []
      after = nil
      loop do
        page = chat.events(after: after, limit: 200)
        items.concat(page.items)
        after = page.next_after
        break if after.nil? || page.items.empty?
      end
      items
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # `message` may be a callable, read only at the flunk — a diagnostic
    # that costs a read is never paid on the green path.
    def await(message, every:)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          text = message.respond_to?(:call) ? message.call : message
          flunk "#{text}; last seen #{latest.inspect}"
        end

        sleep every
      end
    end

    def warn_log(path, label)
      return unless path && File.file?(path)

      warn "---- #{label} (#{path}) ----"
      warn File.read(path, encoding: Encoding::UTF_8).lines.last(80).join
    end
end
