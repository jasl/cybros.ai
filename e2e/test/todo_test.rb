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
require "support/secret_hygiene"
require "support/steward_session"

# THE TODO TRACKER: `todo_write` is one tool on rho's agent address that writes the model's list
# WHOLE as the conversation's memory document `conversation/todo.md` through the member plane's
# conversation door — the kernel's own memory family, so the next turn's memory block shows it again
# and the person's door reads the same row — and answers a receipt of counts, never the list. The
# person's view is transcript-derived: `rho watch`/`rho follow` read the call off the kernel's task
# row once per change; the daemon keeps no table. Under `--approval ask` a bookkeeping write never
# parks (rho's allow rule names it); a shape fault is the RUNNER's, before the handler.
#
# Four tests, each its own daemon and ceremony: the write on every surface;
# the next turn's block; `ask` and the two shape faults; the clear, the
# all-completed clear and the restart (`rho follow` prints the last call's
# list at join off the kernel's row — no daemon state). The mock's scripted
# call is the model's; its echo of the next round is how the journey reads
# what the model was shown (`## user/notes.md`'s precedent, memory_scopes).
#
# SHARED PLUMBING, STATED: every test in this file drives the SAME signed-in
# steward browser (E2E::StewardSession, one per journey process); the
# daemon, its RHO_HOME and every ceremony stay per test.
class TodoTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  DOCUMENT = "conversation/todo.md".freeze
  THREE = [
    { "content" => "Add the CLI entry", "status" => "completed" },
    { "content" => "Parse the input file", "status" => "in_progress" },
    { "content" => "Write the tests", "status" => "pending" },
  ].freeze
  # The document's bytes, as the design records them.
  RENDERED = "- [x] Add the CLI entry\n- [>] Parse the input file\n- [ ] Write the tests".freeze
  # The watch block, line by line.
  BLOCK = ["  todo       - [x] Add the CLI entry",
           "             - [>] Parse the input file",
           "             - [ ] Write the tests"].freeze
  RECEIPT = "Todo list updated: 3 items, 1 completed.".freeze
  CLEARED = "Todo list cleared.".freeze
  # The person's turn's kind on the feed's `turn_status`, beside the
  # kernel's `compaction_summary`.
  REPLY_TURN = "direct_reply".freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-todo-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/todo-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture todo E2E capture: #{error.class}: #{error.message}"
  ensure
    begin
      @daemon&.stop
    rescue StandardError => error
      warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
    end
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  # THE WRITE, EVERY SURFACE: the row completes with the receipt byte for
  # byte; the STEWARD's door reads the document's bytes; `rho watch` prints
  # the block exactly once; `rho task` prints the call; nothing parked;
  # the log carries the counts and no content.
  def test_todo_write_writes_the_conversations_document_and_every_surface_shows_it
    project = connect!
    conversation, _turn, loop = open_turn(todo_prompt(THREE, "done"), project)
    done = await_loop_status(loop, "completed")
    row = todo_row(done)
    key = row.fetch("key")
    assert_equal "completed", row.fetch("status"), summarize(done)
    refute row.dig("result", "is_error"), "a write that landed: #{row.inspect}"
    assert_equal RECEIPT, task_output(loop, key), "the receipt, counts only — never the list"
    assert_equal "agent_application", row.dig("addressed_to", "role"), "the agent's own tool: #{row.inspect}"

    assert_equal RENDERED, door(conversation).read(DOCUMENT).content, "the steward's door reads the same row"

    watched, watch_status = @daemon.cli("watch", loop)
    assert_predicate watch_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^status:\s+completed$/, watched, watched)
    BLOCK.each do |line|
      assert_equal 1, watched.lines.map(&:chomp).count(line), "the block prints exactly once:\n#{watched}"
    end

    printed, task_status = @daemon.cli("task", loop, key)
    assert_predicate task_status, :success?, "rho task failed:\n#{printed}"
    assert_match(/^task:\s+#{Regexp.escape(key)} \(tool_task\) completed$/, printed, printed)
    assert_match(/^tool:\s+todo_write$/, printed, printed)
    # The kernel's jsonb column re-orders keys, so the line is read as JSON.
    assert_equal({ "todos" => THREE }, JSON.parse(printed[/^input:\s+(\{.*\})$/, 1].to_s), "the call's arguments:\n#{printed}")

    status, = @daemon.cli("status")
    assert_match(/^approvals:\s+\(none\)$/, status, "a bookkeeping write never parks:\n#{status}")
    assert_match(/event=todo\.written conversation=#{Regexp.escape(conversation)} items=3 completed=1 bytes=#{RENDERED.bytesize}\b/,
      @daemon.log_text, "the log carries the counts and the bytes:\n#{@daemon.log_text.scan(/event=todo\.\S+.*/).join("\n")}")
    refute_includes @daemon.log_text, "Add the CLI entry", "never the content"
  end

  # THE NEXT TURN SEES IT: the kernel renders the document into the memory
  # block under `## conversation/todo.md` (`memory_block.rb`), and the
  # mock's echo of what it was shown carries the three lines.
  def test_the_next_turn_reads_the_list_in_its_memory_block
    project = connect!
    conversation, _turn, loop = open_turn(todo_prompt(THREE, "done"), project)
    await_loop_status(loop, "completed")
    assert_equal RENDERED, door(conversation).read(DOCUMENT).content

    second = say_turn(conversation, "what is next", except: [loop])
    await_loop_status(second, "completed")
    shown = task_output(second, "r1")
    assert_includes shown, "## #{DOCUMENT}\n#{RENDERED}", "the block rendered the list for the next turn: #{shown.inspect}"
  end

  # UNDER `ask` IT NEVER PARKS (the allow rule names `todo_write`; the fact
  # reads `origin: rule`); A SHAPE FAULT IS THE RUNNER'S: the stranger
  # status and the empty content each answer `invalid_tool_arguments:` as
  # `completed, is_error`, and the document does not move.
  def test_under_ask_the_write_never_parks_and_a_shape_fault_is_the_runners
    project = connect!
    conversation, _turn, loop = open_turn(todo_prompt(THREE, "done"), project, "--approval", "ask")
    done = await_loop_status(loop, "completed")
    refute done.fetch("tasks").any? { |task| task["status"] == "needs_approval" }, summarize(done)
    row = todo_row(done)
    assert_equal "completed", row.fetch("status"), row.inspect
    assert_equal "rule", row.dig("approval", "origin"), "rho's allow rule let it past: #{row.inspect}"
    assert_equal 0, feed(conversation).count { |item| item["type"] == "attention_required" }, "never a park"
    assert_equal RENDERED, door(conversation).read(DOCUMENT).content

    later = say_turn(conversation, todo_prompt([{ "content" => "x", "status" => "later" }], "done", prior: 1), except: [loop])
    refused = todo_row(await_loop_status(later, "completed"))
    assert_equal "completed", refused.fetch("status"), refused.inspect
    assert_equal true, refused.dig("result", "is_error"), "a shape fault is data the model reads: #{refused.inspect}"
    output = task_output(later, refused.fetch("key"))
    assert_match(/\Ainvalid_tool_arguments: value at `\/todos\/0\/status` is not one of: \["pending", "in_progress", "completed"\]/,
      output, "json_schemer's own sentence")
    assert_equal RENDERED, door(conversation).read(DOCUMENT).content, "the document did not move"

    empty = say_turn(conversation, todo_prompt([{ "content" => "", "status" => "pending" }], "done", prior: 2),
      except: [loop, later])
    refused = todo_row(await_loop_status(empty, "completed"))
    assert_equal true, refused.dig("result", "is_error"), refused.inspect
    output = task_output(empty, refused.fetch("key"))
    assert_match(/\Ainvalid_tool_arguments: .*`\/todos\/0\/content`/, output, "minLength, the runner's sentence: #{output.inspect}")
    assert_equal RENDERED, door(conversation).read(DOCUMENT).content, "the document did not move"
    assert_empty @daemon.log_text.scan(/event=todo\.written/).drop(1), "one write landed; the two faults never reached the handler"
  end

  # CLEAR, ALL-COMPLETED, AND THE RESTART: an empty list deletes the
  # document (`rho watch` says `(cleared)` once); a list with every item
  # completed clears it too, with the same receipt; after `rho restart`
  # (the same home, `loops.readopted`), `rho follow` prints the last call's
  # list at join — read off the kernel's task row, no daemon state.
  # EVERY TURN SPEAKS, never its echo: no echo here is read, and an echo
  # repeats the whole request — each earlier echo, and each turn's lead
  # where that turn sent it — so four echoing turns grow the fourth one's
  # history past dev/mock-text's window and the kernel compacts it between
  # turns (`wall`), which the guard refuses. A red run there can also show
  # the fourth turn's `todo_write` answered `failed`, "The tool was
  # interrupted: execution cancelled": a wait that settles before the
  # person's turn has written lets the case fail while that write is in
  # flight, and the teardown's daemon stop answers the claim rho holds —
  # rho's shutdown answer (`Rho::Runner#stop`), never a cancel from the
  # kernel. The first failure is the one to read.
  def test_an_empty_or_finished_list_clears_it_and_a_restarted_daemon_still_shows_the_last_list
    project = connect!
    conversation, _turn, loop = open_turn(todo_prompt(THREE, "done", speak: true), project)
    await_loop_status(loop, "completed")
    assert_equal RENDERED, door(conversation).read(DOCUMENT).content

    cleared = say_turn(conversation, todo_prompt([], "done", prior: 1, speak: true), except: [loop])
    row = todo_row(await_loop_status(cleared, "completed"))
    assert_equal CLEARED, task_output(cleared, row.fetch("key"))
    assert_raises(CybrosAgent::Api::NotFound, "an empty list deletes the document") { door(conversation).read(DOCUMENT) }
    watched, = @daemon.cli("watch", cleared)
    assert_equal 1, watched.lines.map(&:chomp).count("  todo       (cleared)"), "the watch says cleared, once:\n#{watched}"
    assert_match(/event=todo\.cleared conversation=#{Regexp.escape(conversation)}\b/, @daemon.log_text)

    finished = THREE.map { |item| item.merge("status" => "completed") }
    all_done = say_turn(conversation, todo_prompt(finished, "done", prior: 2, speak: true), except: [loop, cleared])
    row = todo_row(await_loop_status(all_done, "completed"))
    assert_equal CLEARED, task_output(all_done, row.fetch("key")), "every item completed: the same receipt"
    assert_raises(CybrosAgent::Api::NotFound) { door(conversation).read(DOCUMENT) }

    again = say_turn(conversation, todo_prompt(THREE, "done", prior: 3, speak: true), except: [loop, cleared, all_done])
    written = await_loop_status(again, "completed")
    refute_compacted(conversation)
    row = todo_row(written)
    assert_equal RECEIPT, task_output(again, row.fetch("key")), "the list written again"
    assert_equal RENDERED, door(conversation).read(DOCUMENT).content

    restart!
    await_replayed(conversation, again)
    followed, follow_status = @daemon.cli("follow", conversation, "--timeout", FOLLOW_SECONDS.to_s)
    assert_predicate follow_status, :success?, "rho follow failed:\n#{followed}"
    lines = followed.lines.map(&:chomp)
    BLOCK.each { |line| assert_equal 1, lines.count(line), "the last call's list at join, once:\n#{followed}" }
    refute_includes followed, "(cleared)", "the older clears are stale by construction:\n#{followed}"
    assert_match(/\(stream ended: turn_settled\)/, followed, followed)
  end

  private

    FOLLOW_SECONDS = 30

    # The mock's scripted call: `todo_write` with the list, then the round
    # after it, which echoes the whole request — or, with `speak:`, says
    # only the remainder (`reply=`). THE FAKE IS STATELESS: it reads which
    # call is next off the count of `function_call_output` items in its
    # whole input, and a later turn's history carries every earlier call of
    # the conversation — so a turn after `prior` scripted calls pads its
    # sequence with that many copies, each carrying the SAME arguments, and
    # whichever element fires is this turn's call. That count holds only on
    # an uncompacted history (`refute_compacted`): a compaction drops the
    # answers and rewinds the clock. A `speak:` line rides into every later
    # turn's history, so a later turn that must echo writes its own marker.
    def todo_prompt(todos, remainder, prior: 0, speak: false)
      element = "todo_write:#{CGI.escape(JSON.generate({ "todos" => todos }))}"
      reply = speak ? " reply=#{CGI.escape(remainder)}" : ""
      "!mock tool_call=#{([element] * (prior + 1)).join(",")}#{reply} -- #{remainder}"
    end

    # THE PADDING'S PRECONDITION: `prior:` counts the answers an UNCOMPACTED
    # history carries, so a compaction anywhere in the conversation fails
    # the case by name rather than letting a turn replay its script.
    def refute_compacted(conversation)
      compacted = feed(conversation).select { |item| item["type"] == "context_compacted" }
      assert_empty compacted.map { |item| item["payload"] },
        "the case reads an uncompacted history: every turn fits the mock's window"
    end

    def todo_row(loop_row)
      loop_row.fetch("tasks").find { |task| task["tool_name"] == "todo_write" } ||
        flunk("the model never called todo_write: #{summarize(loop_row)}")
    end

    # THE STEWARD'S DOOR: the person who owns the work reads the
    # conversation's memory through the SDK, as the webui will.
    def door(conversation)
      steward_client.workspace(@workspace_public_id).conversation(conversation).memory
    end

    def steward_client
      @steward_client ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    end

    # The daemon connected and adopted, the dev lane open, the hosts up,
    # the tools pointed at a project of their own.
    def connect!
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      @daemon.control(:post, "/environment", body: { root: project })
      project
    end

    # THE SAME HOME, BOOTED AGAIN (the MCP journey's shape): the credentials
    # stand, no new grant; a stale announcement would answer the readiness
    # wait for a daemon that is gone, so it is cleared before the boot; the
    # conversation host is re-adopted (`loops.readopted`) before the follow.
    def restart!
      @daemon.stop
      FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
      readopted = @daemon.log_text.scan(/event=loops\.readopted/).length
      @daemon.start
      await_workspace_state("adopted")
      @daemon.await("the conversation host was never re-adopted") do
        @daemon.log_text.scan(/event=loops\.readopted/).length > readopted ? true : nil
      end
    end

    # THE REPLAY CAUGHT UP: a re-adopted host replays the conversation's
    # events from the start, so its table walks every turn again; the
    # daemon's own row names the LAST turn's loop, settled, once it has.
    def await_replayed(conversation, loop)
      @daemon.await("the re-adopted host never replayed to #{loop}") do
        row = Array(@daemon.control(:get, "/loops")["loops"]).find { |candidate| candidate["public_id"] == conversation }
        row if row && row["loop"] == loop && row["complete"]
      end
    end

    # `rho do`: the conversation, its turn, and the loop backing it; the
    # extra flags are the turn's own (`--approval`).
    def open_turn(prompt, project, *flags)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project, *flags)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # `rho say` on a settled conversation opens its next turn; the loop
    # backing it is the one a `direct_reply` turn's `turn_status` names
    # that `except` does not. A BETWEEN-TURN COMPACTION NARRATES FIRST: its
    # `compaction_summary` turn carries the summarizer's own loop, which
    # completes before the person's turn has run a round, so a wait on it
    # would read the document before the write.
    def say_turn(conversation, text, except:)
      said, status = @daemon.cli("say", conversation, text)
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      await("the say never opened a turn", every: LOOP_POLL) do
        opened = feed(conversation).find do |item|
          item["type"] == "turn_status" && item.dig("payload", "turn_kind") == REPLY_TURN &&
            item.dig("payload", "agent_loop_public_id") && !except.include?(item.dig("payload", "agent_loop_public_id"))
        end
        opened&.dig("payload", "agent_loop_public_id")
      end
    end

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("agent_loop") { flunk "the loop read was refused: #{document.inspect}" }
    end

    # The member task read, whole: the row and its bodies.
    def task_detail(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").fetch("task")

    def task_output(loop, task_key) = task_detail(loop, task_key)["output"].to_s

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def await_loop_status(loop, status)
      await("the loop never reached #{status}", every: LOOP_POLL) do
        row = loop_row(loop)
        row if row["status"] == status
      end
    end

    # Paced: the member plane admits 120 loop reads a minute per caller.
    LOOP_POLL = 1
    AWAIT_SECONDS = 90

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

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""}" \
          "#{task.dig("error", "key") ? " !#{task.dig("error", "key")}" : ""})"
      end.join(" ")
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    # The shared steward session (E2E::StewardSession) signed in once for
    # this file; each test lands on the dashboard and asserts it.
    def sign_in_steward
      @actor.visit("/")
      assert @page.has_text?("Dashboard")
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
