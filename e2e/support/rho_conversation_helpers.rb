class RhoConversationTest
  private

    # ---- the file-system port ----

    # The design's one model-facing sentence, as the Conventions extension
    # spells it; the lane pins its presence, never its words (benched, not
    # hand-tuned).
    PORT_SENTENCE = "The editor's open buffers are what read, edit and write see; grep, glob, ls and shell " \
                    "commands see the disk — use edit or write for files open in the editor; a shell write to a " \
                    "file with unsaved changes is invisible to read.".freeze

    # The scripted surface, in this process, with its own mirror; stopped
    # and removed at teardown.
    def fs_server
      mirror = Dir.mktmpdir("rho-fs-mirror")
      (@mirrors ||= []) << mirror
      server = E2E::FsPortServer.new(mirror: mirror).start
      (@fs_servers ||= []) << server
      server
    end

    # `rho-dev port ID --endpoint U --token T [--read] [--write]`: the door's
    # `fs:` member from the terminal; the verb prints the flags, never
    # the token.
    def register_port(conversation, server, *flags)
      printed, status = @daemon.cli("port", conversation, "--endpoint", server.url, "--token", server.token, *flags)
      assert_predicate status, :success?, "rho-dev port failed:\n#{printed}"
      assert_match(/^fs:\s+on — rho-dev \(/, printed, "the verb reports the port on:\n#{printed}")
      refute_includes printed, server.token, "the token never prints"
      printed
    end

    # The first call of a tool on a loop, its result text; a call that
    # never happened flunks with the loop's shape.
    def tool_result_of(loop, name)
      row = loop_row(loop)
      task = row.fetch("tasks").find { |candidate| candidate["tool_name"] == name }
      refute_nil task, "the loop never called #{name}: #{summarize(row)}"
      tool_result(loop, task.fetch("key"))
    end

    # ---- the editor's MCP servers ----

    # The verb's spelling that closes a conversation's servers.
    MCP_CLOSE = "[]".freeze

    # THE FIXTURE, the http entry (`mcp_tools`'s boot, shared through
    # `E2E::McpFixture::Host`): puma on a loopback port the journey picks,
    # spawned under rho-mcp's bundle in its own group, ready once the
    # port answers; its url is what the file's entry carries. Stopped at
    # teardown, its log read on a red run.
    def mcp_fixture_url
      port = E2E::McpFixture::Host.free_port
      @mcp_fixture_log = File.join(@home, "mcp-fixture.log")
      @mcp_fixture_pid = E2E::McpFixture::Host.spawn(entry: "http", port: port, log: @mcp_fixture_log)
      E2E::McpFixture::Host.await_ready!(port, log: @mcp_fixture_log)
      "http://127.0.0.1:#{port}/mcp"
    rescue E2E::McpFixture::Host::NotListening => error
      flunk "the http fixture never listened: #{error.message}"
    end

    # A FILE in the ACP `mcpServers` shape, beside the project — what
    # `rho-dev environment ID --mcp FILE.json` reads whole.
    def mcp_file(name, entries)
      File.join(@project, "#{name}.json").tap { |path| File.write(path, JSON.pretty_generate(entries), encoding: Encoding::UTF_8) }
    end

    # `rho-dev environment ID --mcp FILE.json` (or `[]`): the door's `mcp:`
    # member from the terminal; the verb prints the rows, never a value.
    def bind_servers(conversation, spelling)
      printed, status = @daemon.cli("environment", conversation, "--mcp", spelling)
      assert_predicate status, :success?, "rho-dev environment --mcp failed:\n#{printed}"
      printed
    end

    # The verb's `mcp:` lines, as printed.
    def mcp_rows(printed) = printed.lines.map(&:chomp).grep(/^mcp:/)

    # A scripted call of the fixture's `echo` under its public name.
    def echo(text) = ["mcp__fx__echo", { "text" => text }]

    # The one call of a prefixed tool the mock made on a loop.
    def mcp_call(row, name)
      row.fetch("tasks").find { |task| task["tool_name"] == name } || flunk("the mock never called #{name}: #{summarize(row)}")
    end

    # An MCP answer's TEXT: the task's `output`, as the mcp_tools lane
    # reads the same fixture's echo (`task_output`). The kernel's task
    # detail serves the text twice — `output` is the body's text,
    # `content` the stored blocks, the one text block of the same bytes
    # (agent_loop_presenter `task_detail`) — and this lane's `tool_result`
    # joins both for the port rows' pins, which doubled the echo here; the
    # pin stays byte-exact on the one field that is the answer.
    def mcp_output(loop, task_key)
      document = agent_api("#{loop_path(loop)}/tasks/#{task_key}")
      task = document.fetch("task") { flunk "the task read was refused: #{document.inspect}" }
      task["output"].to_s
    end

    # A round's SEALED REQUEST `tools`: the declarations the kernel holds
    # for the names the turn was offered (its narrowing by the turn's
    # names, decision 19) — the announced bytes as the model received them.
    def sealed_tools(loop, task_key = "r1")
      request = steward_client.workspace(@workspace_public_id).agent_loops.agent_loop(loop).tasks_context(task_key).request
      Array(request.request_options["tools"])
    end

    # The names a round OFFERED the model, off its sealed request.
    def sealed_tool_names(loop, task_key = "r1") = sealed_tools(loop, task_key).map { |tool| tool.dig("function", "name") }

    # rho's AGENT executor (the daemon's own), the id the kernel names on
    # a call it addresses to the editor's server: `identity.
    # executor_public_id` off `rho status`.
    def rho_agent_id
      @rho_agent_id ||= @daemon.status.dig("identity", "executor_public_id") ||
        flunk("a full-mode rho registers an agent row: #{@daemon.status.inspect}")
    end

    # THE FIXTURE'S NAMES under an editor's row: `Settings.from_acp` gives
    # the row `tools: "*"` (the editor curates, not the operator), and
    # `"*"` announces every tool the server lists that has a description
    # and a schema json_schemer accepts — all seven of
    # `E2E::McpFixture::TOOLS`, as the mcp_tools lane's http row announces
    # them; the daemon's `mcp_servers.bound tools=7` line says the same.
    FIXTURE_TOOLS = E2E::McpFixture::TOOLS.length

    # THE AGENT SLOT'S ANNOUNCEMENTS, read where they are written — the
    # member plane cannot show them: `GET /executors` and its `show` list
    # ADDRESSABLE kinds alone (executors_controller's `addressable`, the
    # machine kinds a member may address), and an agent address "binds
    # nothing and is nobody's to address" (the SDK's `Executors`) — `show`
    # on rho's agent id is `NotFound` to a member, by design, so its
    # `served_tools` is never readable here. The daemon logs
    # `executor.announced` with `address=agent` and the list's length
    # AFTER the kernel accepted the PUT (executor_plane.rb
    # `announce_tools`), and the slot's list is the registry's entries
    # union every anchor's served entries, a name once (daemon.rb
    # `announce_slot`): the counts, oldest first, are the witness — a bind
    # lands a NEW line counting the fixture's names on top of the slot's
    # own, and the last close one counting them off.
    def agent_announcements
      @daemon.log_lines.filter_map do |line|
        Integer(line.fetch("tools")) if line["event"] == "executor.announced" && line["address"] == "agent"
      end
    end

    # A NEW agent-slot announcement past `seen` lines, counting `tools`:
    # a moved table re-announces on the reactor (`servers_changed` →
    # `reannounce(:agent_runner)`), so the verb returns before the line
    # lands. Answers the counts, the next call's `seen`.
    def await_agent_announcement(seen, tools)
      await("the agent slot never announced #{tools} tools past its #{seen} announcement(s)", every: LOOP_POLL) do
        counts = agent_announcements
        counts.length > seen && counts.last == tools ? counts : nil
      end
    end

    # ---- the conversation's environment ----

    # A directory a conversation is bound to: REALPATH'd, so the spelling
    # the record carries and the lead names is the one asserted (macOS's
    # `/var` is `/private/var` by the time rho has spelled it); beside the
    # home, never under it (a protected root), removed at teardown.
    def bound_directory(name)
      File.realpath(Dir.mktmpdir("rho-environment-#{name}")).tap { |dir| (@bound_directories ||= []) << dir }
    end

    # The fake's script (the spawn lane's shape): one scripted call per round, each with its own
    # url-encoded arguments, then the remainder. `reply: true` MAKES THE ANSWER THE REMAINDER, NEVER
    # THE ECHO: the fake echoes the whole joined input as its reply, so a row of seven turns doubles
    # its history every turn — the port row read 1 306, 2 251, 4 518 input tokens on its turns 2–4
    # against the dev window's 8 192 — and by turn 5 the kernel arms the between-turn summary
    # (`apply_next`'s `over_usage`), whose loop is what `rho say` then names; the summarizer's own
    # echo is as large as the history it replaces (conversation_turn_test scripts its summary short
    # for the same reason). The port rows read no echo — every pin there is on a tool's result or a
    # sealed request; so do the E1 lead rows: the lead rides every say and a pin on a later say's
    # sealed request must not be met by turn 1's lead echoed back through the history, which is how
    # the per-change gate passed E1 while sending no lead. The rows of one or two turns keep the
    # echo they were cut on.
    def script(calls, remainder, reply: false)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      spoken = reply ? " reply=#{CGI.escape(remainder)}" : ""
      "!mock tool_call=#{spelled.join(",")}#{spoken} -- #{remainder}"
    end

    # A relative `write`: where it lands is the conversation's root.
    def note(path, text) = ["write", { "path" => path, "content" => "#{text}\n" }]

    # `rho say` on a followed row, and the loop it opened.
    def rho_say_loop(host, text)
      said, status = @daemon.cli("say", host, text)
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      loop_id = said[/^loop:\s+(\S+)/, 1]
      refute_nil loop_id, "rho say printed no loop:\n#{said}"
      loop_id
    end

    # THE LEAD, off the round's sealed request: the root sentence
    # (`Coding::Report`) of the NEWEST lead names the conversation's bound
    # root — an earlier turn's lead rides in history where that turn sent
    # it, so only the last one is this turn's.
    def assert_lead_names(loop, root)
      words = sealed_words(loop, "r1")
      newest = words.rindex("Relative paths resolve against ")
      refute_nil newest, "the round of #{loop} carries no lead"
      assert words[newest..].start_with?("Relative paths resolve against #{root}."),
        "the newest lead of #{loop} names #{root}: #{words[newest, 200].inspect}"
    end

    # THE NEWEST LEAD's words, off the round's sealed request: the last
    # developer entry opening with the root sentence. An earlier turn's lead
    # rides in history where that turn sent it, so what this turn's lead
    # carries — or left out — is read here, never off the request whole.
    def newest_lead_words(loop, task_key)
      entries = agent_api("#{loop_path(loop)}/tasks/#{task_key}/request").dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop} has no sealed request"
      lead = entries.reverse.find do |entry|
        entry["role"] == "developer" && entry.dig("parts", 0, "text").to_s.start_with?("Relative paths resolve against ")
      end
      refute_nil lead, "the round #{task_key} of #{loop} carries no lead"
      lead.fetch("parts").filter_map { |part| part["text"] }.join("\n")
    end

    # How many leads the round's sealed request carries — the developer
    # entries opening with the root sentence: the kernel lays a lead once
    # per window, so a say whose lead equals the newest one its history
    # carries lays none.
    def lead_count(loop, task_key)
      entries = agent_api("#{loop_path(loop)}/tasks/#{task_key}/request").dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop} has no sealed request"
      entries.count do |entry|
        entry["role"] == "developer" && entry.dig("parts", 0, "text").to_s.start_with?("Relative paths resolve against ")
      end
    end

    # Every string the round's sealed request carries, joined.
    def sealed_words(loop, task_key)
      document = agent_api("#{loop_path(loop)}/tasks/#{task_key}/request")
      entries = document.dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop} has no sealed request: #{document.inspect}"
      texts_of(entries).join("\n")
    end

    def texts_of(value)
      case value
      when String then [value]
      when Array then value.flat_map { |item| texts_of(item) }
      when Hash then value.values.flat_map { |item| texts_of(item) }
      else []
      end
    end

    def steward_client
      @steward_client ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    end

    # The conversation's store, through the SDK as the steward.
    def store(conversation) = steward_client.workspace(@workspace_public_id).conversation(conversation).store_entries

    # rho's record in a conversation's store: the `rho.environment`/`binding`
    # row, read whole (the listing carries no value).
    def binding_record(conversation)
      summary = store(conversation).list.items.find { |row| row.namespace == "rho.environment" && row.key == "binding" }
      refute_nil summary, "no rho.environment/binding row in the store of #{conversation}"
      store(conversation).fetch(summary.public_id)
    end

    # The first completed assistant turn on a conversation; a failed one flunks.
    def await_completed_reply(chat)
      await("no reply settled on #{chat.public_id}", every: FEED_POLL) do
        turns = chat.turns.list.items.select { |turn| turn.role == "assistant" }
        failed = turns.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        turns.find { |turn| turn.status == "completed" }
      end
    end

    # THE SAME HOME, BOOTED AGAIN (the approval lane's shape): the
    # credentials stand; a stale announcement would answer the readiness
    # wait for a daemon that is gone, so it is cleared; the conversation
    # host is re-adopted (`loops.readopted`) and the boot's own declaration
    # has landed (`profile.declared`) before the next turn.
    def restart_daemon!
      readopted = @daemon.log_lines.count { |line| line["event"] == "loops.readopted" }
      declared = @daemon.log_lines.count { |line| line["event"] == "profile.declared" }
      @daemon.stop
      FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
      @daemon.start
      await_workspace_state("adopted")
      @daemon.await("the conversation host was never re-adopted") do
        @daemon.log_lines.count { |line| line["event"] == "loops.readopted" } > readopted ? true : nil
      end
      @daemon.await("the booted daemon never declared its profile") do
        @daemon.log_lines.count { |line| line["event"] == "profile.declared" } > declared ? true : nil
      end
    end

    # The held call on a loop: the tool task resting `needs_approval`.
    def await_park(loop)
      await("the call never parked", every: LOOP_POLL) do
        row = loop_row(loop)
        row.fetch("tasks").find { |task| task["kind"] == "tool_task" && task["status"] == "needs_approval" }
      end
    end

    # The daemon connected and adopted, the dev lane open, the hosts up
    # (materialization is `DrainJob`'s) — before the first `rho do`.
    def connect!
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      # THE PROJECT LIVES BESIDE THE HOME, never under it: `$RHO_HOME` is a protected root — the
      # incubation denies name it by its realpath and the Guard's floor resolves a `write`/`edit`
      # path before judging it, so an absolute write under `<home>/project` is refused on every
      # runner (the raw `/var` spelling that escaped the denies on macOS escapes the floor no
      # longer). The person's checkout is its own directory, as the `approval` lane's "outside"
      # project is.
      @project = Dir.mktmpdir("rho-conversation-project")
    end

    # `rho do`, and the output contract: the conversation, its turn, and the loop backing it, then
    # the compose tier with its source — no status, no tools. Answers the three ids and the whole
    # output, for a case that reads the tier. `model:` names another catalog row; the compose tier's
    # source is one of the ladder's four rungs.
    def open_turn(prompt, project, *flags, model: MODEL)
      output, status = @daemon.cli("do", prompt, "--model", model, "--dir", project, *flags)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      assert_match(/^loop:.*\ncompose:\s+(on|off) \((flag|settings|default|row [a-z0-9.-]+)\)$/, output,
        "the tier follows the loop line:\n#{output}")
      refute_match(/^status:/, output, output)
      refute_match(/^tools:/, output, output)
      ids + [output]
    end

    # The home's `settings.json` BEFORE the boot: the lane's knobs over the
    # dev set — the fixture writes nothing on a file that exists.
    def write_settings!(**knobs)
      File.write(File.join(@home, "settings.json"), JSON.generate(E2E::RhoDaemon::DEV_SETTINGS.merge(knobs)),
        encoding: Encoding::UTF_8)
    end

    # A LOCAL ADAPTATION ROW under the home's `adaptations/`, read at boot.
    def write_local_row(id, yaml)
      FileUtils.mkdir_p(File.join(@home, "adaptations"))
      File.write(File.join(@home, "adaptations", "#{id}.yml"), yaml)
    end

    # The one call the mock made as `Agent` on a loop.
    def agent_call(row)
      row.fetch("tasks").find { |task| task["tool_alias"] == "Agent" } ||
        flunk("no call was made as Agent: #{summarize(row)}")
    end

    # The one `compose` call the mock was scripted to make on a loop.
    def compose_call(row)
      row.fetch("tasks").find { |task| task["tool_name"] == "compose" } ||
        flunk("the mock never called compose: #{summarize(row)}")
    end

    def turn_status(items, status:, loop:)
      items.find do |item|
        item["type"] == "turn_status" && item.dig("payload", "status") == status &&
          item.dig("payload", "agent_loop_public_id") == loop
      end
    end

    # Every turn the feed opened on a loop other than `except`, in feed
    # order — the drain's own order, which is what the mail cases read.
    def new_turns(items, except:)
      items.select do |item|
        item["type"] == "turn_status" && item.dig("payload", "status") == "running" &&
          !except.include?(item.dig("payload", "agent_loop_public_id"))
      end.sort_by { |item| item.fetch("sequence") }
    end

    # The materialization that opened a turn: the input it drained.
    def materialized(items, opened)
      items.find { |item| item["type"] == "input_materialized" && item.dig("payload", "turn_public_id") == opened.dig("payload", "turn_public_id") } ||
        flunk("no materialization named the turn #{opened.inspect}: #{types(items)}")
    end

    # The conversation's queue as the member plane lists it (read order).
    def inputs(conversation)
      agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/inputs").fetch("inputs")
    end

    def types(items) = items.map { |item| item["type"] }.inspect

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("agent_loop") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_output(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").dig("task", "output").to_s

    # The arguments ride the single-task read, never the trace.
    def tool_input(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").dig("task", "tool_input")

    # A tool task's result reads as the grammar's content blocks, beside
    # whatever text the task read carries as `output`.
    def tool_result(loop, task_key)
      document = agent_api("#{loop_path(loop)}/tasks/#{task_key}")
      task = document.fetch("task") { flunk "the task read was refused: #{document.inspect}" }
      [task["output"], *Array(task["content"]).map { |block| block["text"] }].compact.join
    end

    # The conversation's whole feed, paged through the replay window.
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

    def await_feed(conversation, message)
      await(message, every: FEED_POLL) { yield(feed(conversation)) }
    end

    # ONE SWEEP OF THE RUNNER'S CLOCK (`Rho::Runner::SWEEP_SECONDS`, 5 s)
    # and a margin: the cancel rides the cable and lands in milliseconds,
    # and even a runner carried by its own polling has met the row by then.
    GROUP_DEAD_SECONDS = 8

    def process_group_alive?(pgid)
      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      # macOS answers EPERM for a group of nothing but zombies: not gone
      # until its leader is reaped, which is the runner's `kill_and_reap`.
      true
    end

    def await_process_group_gone(pgid, within:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        return true unless process_group_alive?(pgid)

        sleep 0.2
      end
      !process_group_alive?(pgid)
    end

    def rho_log
      path = File.join(@home, "log", "rho.log")
      File.file?(path) ? File.read(path, encoding: Encoding::UTF_8) : ""
    end

    def await_tool_running(loop)
      await("the slow tool never started", every: LOOP_POLL) do
        row = loop_row(loop)
        row if row.fetch("tasks").any? { |task| task["kind"] == "tool_task" && %w[dispatched running].include?(task["status"]) }
      end
    end

    def await_loop_status(loop, status)
      await("the loop never reached #{status}", every: LOOP_POLL) do
        row = loop_row(loop)
        row if row["status"] == status
      end
    end

    # The daemon's own follower row (Ops's `GET /loops`), keyed by the
    # conversation and pointing at the loop backing its CURRENT turn.
    # The follower reads the feed on its own fiber, so its record of the
    # turn's completed and of the mail it read arrive one item apart: a
    # case that asserts `mailed` waits for it, never for the item before.
    def await_follower(conversation, loop:, mailed: false)
      await("the follower never read the turn's completed#{" and the mail" if mailed} on loop #{loop}", every: 0.5) do
        row = @daemon.control(:get, "/loops").fetch("loops").find { |candidate| candidate.fetch("public_id") == conversation }
        row if row && row["loop"] == loop && row["complete"] && (!mailed || row["mailed"].to_a.any?)
      end
    end

    # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
    # routes, 600 on a feed), and every case here reads as the same
    # steward — so a poll is paced, not tight: a journey that polled at the
    # daemon's cadence spent the next case's budget and read `rate_limited`
    # where it expected a loop.
    LOOP_POLL = 1
    FEED_POLL = 1
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
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name: the
    # test process inherits the machine's empty locale.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    # ---- the answered conversation ----

    # rho's profile and runner as `rho status` prints them, once the
    # daemon has announced the runner's tools and declared the profile —
    # the conversation the case opens needs both before its first head.
    def rho_identity
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
      @daemon.await("rho never declared its profile") do
        @daemon.log_lines.find { |line| line["event"] == "profile.declared" }
      end
      printed, status = @daemon.cli("status")
      assert_predicate status, :success?, "rho status failed:\n#{printed}"
      assert_match(/^runner:\s+\S+ serving \d+ tools/, printed, "rho's runner is not serving:\n#{printed}")
      ids = [printed[/^profile:\s+(\S+)/, 1], printed[/^runner:\s+(\S+)/, 1]]
      refute_includes ids, nil, "rho status printed no profile or runner line:\n#{printed}"
      ids
    end

    # A second agent program, paired through the steward's own session
    # (the same person stewards rho): the member plane as that program.
    # It declares nothing — that is the case's point.
    def pair_peer_program
      E2E::PeerProgram.pair(base_url: @base_url, actor: @actor, name: "peer").client
    end

    # One `direct_reply` on the conversation, as whoever `chat` speaks for,
    # and its settled reply: the first completed assistant turn past the
    # positions already on the timeline (memory_scopes's shape).
    def ask(chat, text)
      after = chat.turns.list.items.map(&:position).max || -1
      chat.inputs.create(kind: "direct_reply", model: MODEL, text: text, idempotency_key: SecureRandom.uuid)
      await("no reply settled for #{text.inspect}", every: FEED_POLL) do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply to #{text.inspect} failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    # A loop read in a workspace other than rho's adopted one, through the
    # SDK as the person who owns it.
    def await_loop_status_in(client, workspace_public_id, loop_id, status)
      refute_nil loop_id, "no loop backs the turn"
      await("the loop #{loop_id} never reached #{status}", every: LOOP_POLL) do
        row = client.workspace(workspace_public_id).agent_loop(loop_id).fetch
        row if row.status == status
      end
    end

    # The plain workspace the answered case created, tombstoned at the end
    # — best effort, as the memory scopes lane leaves its residue.
    def restore_answered_workspace
      client, public_id = @answered_workspace
      return if client.nil?

      client.workspace(public_id).delete(lock_version: client.workspaces.fetch(public_id).lock_version)
    rescue StandardError => error
      warn "Could not delete the answered workspace #{public_id}: #{error.class}: #{error.message}"
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
    # this file; each test lands on the dashboard and asserts it — the same
    # assertion the per-test sign-in made, now against the shared session.
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
