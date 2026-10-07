class RhoAcpAgentTest
  private

    # ---- the surface ----

    # `rho-acp` under its own bundle on the lane's home, the default
    # model the mock's row (a bare home holds no `default_model`).
    def surface(*flags, home: @world.home, policy: {}, buffers: {})
      index = @clients.length
      client = E2E::AcpClient.spawn(
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho-acp", "--model", MODEL, *flags],
        env: SURFACE_BUNDLE_ENV.merge("RHO_HOME" => home, "RHO_NEXUS_URL" => @base_url),
        chdir: RHO_ACP_ROOT, stderr: File.join(@scratch, "surface-#{index}.stderr"), policy: policy, buffers: buffers
      )
      @clients << client
      client
    end

    def ready(*flags, capabilities: Methods::BASELINE_CLIENT_CAPABILITIES, **options)
      client = surface(*flags, **options)
      client.initialize_agent(capabilities: capabilities, timeout: SPAWN_TIMEOUT)
      client
    end

    # `rho-acp WORD` on the lane's home, bounded: the output and the status.
    def run_surface(*words)
      output = +""
      status = nil
      io = IO.popen(
        SURFACE_BUNDLE_ENV.merge("RHO_HOME" => @world.home, "RHO_NEXUS_URL" => @base_url),
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho-acp", *words],
        chdir: RHO_ACP_ROOT, in: File::NULL, err: [:child, :out], pgroup: true
      )
      begin
        Timeout.timeout(SPAWN_TIMEOUT) { output = io.read.force_encoding(Encoding::UTF_8).scrub }
      rescue Timeout::Error
        E2E::ProcessRunner.terminate(io.pid)
        flunk "rho-acp #{words.join(" ")} did not exit within #{SPAWN_TIMEOUT}s:\n#{output}"
      end
      io.close
      status = $?
      [output, status]
    end

    def open_session(client, cwd: nil, mcp_servers: [])
      open_with_document(client, cwd: cwd, mcp_servers: mcp_servers).first
    end

    def open_with_document(client, cwd: nil, mcp_servers: [])
      document = client.request(Methods::SESSION_NEW, { "cwd" => cwd || project, "mcpServers" => mcp_servers }, timeout: PROMPT_TIMEOUT)
      [document.fetch("sessionId"), document]
    end

    def say(client, session, prompt) = client.prompt(session, prompt, timeout: PROMPT_TIMEOUT)

    # A directory a session is bound to: REALPATH'd (macOS's `/var` is
    # `/private/var` by the time rho has spelled it), beside the home and
    # never under it (a protected root), removed at teardown.
    def project(name = "project")
      File.realpath(Dir.mktmpdir("rho-acp-agent-#{name}")).tap { |dir| @dirs << dir }
    end

    def stop_quietly(label)
      yield
    rescue StandardError => error
      warn "Could not stop #{label}: #{error.class}: #{error.message}"
    end

    # A home of the lane's own with the settings given; the doors case
    # boots one on it, never connected.
    def home_with(settings)
      Dir.mktmpdir("rho-acp-agent-home").tap do |home|
        @dirs << home
        File.write(File.join(home, "settings.json"), JSON.generate(settings), encoding: Encoding::UTF_8, perm: 0o600)
      end
    end

    def selected(option_id)
      { "outcome" => { "outcome" => Methods::PermissionOutcome::SELECTED, "optionId" => option_id } }
    end

    # ---- the mock's scripts ----

    def reply_prompt(words, remainder = "say it") = "!mock reply=#{CGI.escape(words)} -- #{remainder}"

    # One scripted call per round, each with its own url-encoded
    # arguments, then the remainder SPOKEN (`reply=`): the fake echoes its
    # whole input otherwise, and a session of several turns would double
    # its history every turn. THE MOCK'S CLOCK IS THE WHOLE INPUT
    # (`support/mock_llm/directives.rb`'s header; the `rho_conversation`
    # receipt lane pads `bash,bash` for the same reason): the round it
    # serves is the count of tool answers already present — and a later
    # turn's input carries every earlier turn's answers on this
    # conversation — so a script on a turn after tool-calling turns names
    # `spent` groups ahead of its own, one per answer the history holds,
    # or the fake speaks at once and calls nothing.
    def script(calls, remainder, spent: 0)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      padded = Array.new(spent, calls.first.first) + spelled
      "!mock tool_call=#{padded.join(",")} reply=#{CGI.escape(remainder)} -- #{remainder}"
    end

    def bash(command) = ["bash", { "command" => command }]

    def write_call(path, content) = ["write", { "path" => path, "content" => content }]

    def edit_call(path, old_text, new_text) = ["edit", { "path" => path, "edits" => [{ "oldText" => old_text, "newText" => new_text }] }]

    def read_call(path) = ["read", { "path" => path }]

    def ask_call(question) = ["ask", { "prompt" => question }]

    def todo_call(todos) = ["todo_write", { "todos" => todos }]

    def echo_call(text) = ["mcp__fx__echo", { "text" => text }]

    # ---- what the wire carried ----

    def updates_of(turn, kind) = turn.updates.select { |update| update.fetch(Methods::SESSION_UPDATE_DISCRIMINATOR) == kind }

    def tool_calls(turn) = updates_of(turn, Update::TOOL_CALL)

    def tool_call_updates(turn, id) = updates_of(turn, Update::TOOL_CALL_UPDATE).select { |update| update.fetch("toolCallId") == id }

    def kinds(turn) = turn.updates.map { |update| update.fetch(Methods::SESSION_UPDATE_DISCRIMINATOR) }.inspect

    # "<turn>:<n>" — the turn id the reply's chunks name.
    def turn_id_of(turn)
      chunk = updates_of(turn, Update::AGENT_MESSAGE_CHUNK).first || flunk("no agent chunk on the turn: #{kinds(turn)}")
      chunk.fetch("messageId").rpartition(":").first
    end

    # "<loop>:<key>" — the loop and the task key a tool call names.
    def loop_and_key(tool_call_id)
      loop_id, _separator, key = tool_call_id.rpartition(":")
      refute_empty loop_id, "the toolCallId names its loop: #{tool_call_id.inspect}"
      [loop_id, key]
    end

    # Tool updates are partial: a status-only frame keeps the last content,
    # while an explicit empty content replaces it. Fold in received order;
    # a late follower may see an already-completed `tool_call` snapshot.
    def tool_call_state(turn, id)
      turn.updates.reduce(nil) do |state, frame|
        kind = frame.fetch(Methods::SESSION_UPDATE_DISCRIMINATOR)
        next state unless [Update::TOOL_CALL, Update::TOOL_CALL_UPDATE].include?(kind) && frame.fetch("toolCallId") == id

        (state || {}).merge(frame)
      end
    end

    def assert_completed_with_preview(update)
      refute_nil update, "no frame settled the call"
      assert_equal Methods::ToolCallStatus::COMPLETED, update.fetch("status"), update.inspect
      content = update.fetch("content")
      assert_equal 1, content.length, update.inspect
      assert_equal %w[content text], [content.first.fetch("type"), content.first.dig("content", "type")], update.inspect
      refute_empty content.first.dig("content", "text").to_s, "the preview carries the output"
    end

    # The configuration document contains the supported modes, model references currently known to
    # the session, and the conversation's Code Mode choice.
    def assert_config_options(options, mode:, model:)
      assert_equal %w[mode model code_mode], options.map { |option| option.fetch("id") }, options.inspect
      mode_option, model_option, code_mode_option = options
      assert_equal({ "id" => "mode", "category" => "mode", "type" => "select", "currentValue" => mode },
        mode_option.slice("id", "category", "type", "currentValue"))
      assert_equal MODE_ROWS.map { |row| row.fetch("id") }, mode_option.fetch("options").map { |option| option.fetch("value") }
      assert_equal MODE_ROWS.map { |row| row.fetch("name") }, mode_option.fetch("options").map { |option| option.fetch("name") }
      assert_equal({ "id" => "model", "category" => "model", "type" => "select", "currentValue" => model },
        model_option.slice("id", "category", "type", "currentValue"))
      values = model_option.fetch("options").map { |option| option.fetch("value") }
      assert_includes values, MODEL, "the mock's row is offered: #{values.inspect}"
      assert_equal values.uniq, values
      model_option.fetch("options").each { |option| assert_kind_of String, option.fetch("name"), option.inspect }
      assert_equal({ "id" => "code_mode", "name" => "Code Mode", "type" => "select", "currentValue" => "default",
        "options" => [
          { "value" => "default", "name" => "rho default" },
          { "value" => "on", "name" => "On" },
          { "value" => "off", "name" => "Off" },
        ] }, code_mode_option)
    end

    # The stdout position of the response to request `id`.
    def response_index(client, id)
      stdout_index(client) { |message| message["id"] == id && (message.key?("result") || message.key?("error")) }
    end

    # The stdout position of the first `session/update` of `kind` on `session`.
    def notification_index(client, session, kind)
      stdout_index(client) do |message|
        message["method"] == Methods::SESSION_UPDATE && message.dig("params", "sessionId") == session &&
          message.dig("params", "update", Methods::SESSION_UPDATE_DISCRIMINATOR) == kind
      end
    end

    def stdout_index(client)
      index = client.stdout_lines.index { |line| yield(JSON.parse(line)) rescue false }
      refute_nil index, "no such line on stdout:\n#{client.stdout_lines.join("\n")}"
      index
    end

    # The session's updates the agent wrote BEFORE it answered request `id`.
    def replayed_before_response(client, session, id)
      client.stdout_lines.first(response_index(client, id)).filter_map do |line|
        message = JSON.parse(line)
        next unless message["method"] == Methods::SESSION_UPDATE && message.dig("params", "sessionId") == session

        message.dig("params", "update")
      end
    end

    # Every line the surface wrote is one JSON-RPC 2.0 message.
    def assert_wire_only(client)
      client.stdout_lines.each do |line|
        message = JSON.parse(line)
        assert_equal Methods::JSONRPC, message["jsonrpc"], "not a JSON-RPC message on stdout: #{line}"
      rescue JSON::ParserError
        flunk "stdout carried a line that is not JSON: #{line.inspect}\n#{client.stderr}"
      end
    end

    def upload_ids(entries)
      entries.flat_map { |entry| entry.fetch("parts", []) }
        .select { |part| part["type"] == "upload" }.map { |part| part["upload_public_id"] }
    end

    def texts_of(value)
      case value
      when String then [value]
      when Array then value.flat_map { |item| texts_of(item) }
      when Hash then value.values.flat_map { |item| texts_of(item) }
      else []
      end
    end

    # ---- the daemon's door, rho's product verbs ----

    def follower(session)
      @daemon.control(:get, "/followers").fetch("followers").find { |row| row.fetch("public_id") == session }
    end

    def environment_of(session)
      @daemon.control(:get, "/conversations/environment?public_id=#{URI.encode_www_form_component(session)}").fetch("environment")
    end

    def rho_env
      output, status = @daemon.cli("env")
      assert_predicate status, :success?, "rho env failed:\n#{output}"
      output
    end

    # THE SAME HOME, BOOTED AGAIN (the approval lane's shape): the
    # credentials stand; the announcement was cleared with the store.
    def restart_daemon!
      @daemon.start
      self.class.await_workspace_adopted(@daemon)
      @daemon.await_announced(address: "agent")
    end

    # THE FIXTURE, the http entry (`mcp_tools`'s boot, shared through
    # `E2E::McpFixture::Host`): puma on a loopback port the journey picks,
    # spawned under rho-mcp's bundle in its own group, ready once the
    # port answers; stopped at teardown, its log read on a red run.
    def mcp_fixture_url
      port = E2E::McpFixture::Host.free_port
      @mcp_fixture_log = File.join(@scratch, "mcp-fixture.log")
      @mcp_fixture_pid = E2E::McpFixture::Host.spawn(entry: "http", port: port, log: @mcp_fixture_log)
      E2E::McpFixture::Host.await_ready!(port, log: @mcp_fixture_log)
      "http://127.0.0.1:#{port}/mcp"
    rescue E2E::McpFixture::Host::NotListening => error
      flunk "the http fixture never listened: #{error.message}"
    end

    # ---- the kernel, as the steward reads it ----

    def steward_client
      @steward_client ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    end

    def loop_path(loop_id) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop_id}"

    def loop_row(loop_id)
      document = agent_api(loop_path(loop_id))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_detail(loop_id, task_key)
      document = agent_api("#{loop_path(loop_id)}/tasks/#{task_key}")
      document.fetch("task") { flunk "the task read was refused: #{document.inspect}" }
    end

    def task_output(loop_id, task_key) = task_detail(loop_id, task_key)["output"].to_s

    # Every string the round's sealed request carries, joined.
    def sealed_words(loop_id, task_key)
      document = agent_api("#{loop_path(loop_id)}/tasks/#{task_key}/request")
      entries = document.dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop_id} has no sealed request: #{document.inspect}"
      texts_of(entries).join("\n")
    end

    def await_run_status(loop_id, status)
      await("the loop #{loop_id} never reached #{status}", every: POLL) do
        row = loop_row(loop_id)
        row if row["status"] == status
      end
    end

    def await_task_status(loop_id, task_key, statuses)
      await("the task #{task_key} of #{loop_id} never reached #{statuses.join("/")}", every: POLL) do
        task = loop_row(loop_id).fetch("tasks").find { |candidate| candidate["key"] == task_key }
        task if task && statuses.include?(task["status"])
      end
    end

    # The model's ask on a loop: the await task resting `awaiting_input`.
    def await_ask(loop_id)
      await("the model never asked on #{loop_id}", every: POLL) do
        loop_row(loop_id).fetch("tasks").find { |task| task["kind"] == "await_task" && task["status"] == "awaiting_input" }
      end
    end

    def await_ask_settled(loop_id)
      await("the ask on #{loop_id} never settled", every: POLL) do
        loop_row(loop_id).fetch("tasks").find { |task| task["kind"] == "await_task" && task["status"] == "completed" }
      end
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
      await(message, every: POLL) { yield(feed(conversation)) }
    end

    def turn_status(items, status:, loop:)
      items.find do |item|
        item["type"] == "turn_status" && item.dig("payload", "status") == status &&
          item.dig("payload", "run_public_id") == loop
      end
    end

    def types(items) = items.map { |item| item["type"] }.inspect

    # The feed's word on a turn: its `turn_status` at `status`.
    def await_turn(conversation, turn_id, status)
      await_feed(conversation, "the turn #{turn_id} never reached #{status}") do |items|
        items.find do |item|
          item["type"] == "turn_status" && item.dig("payload", "status") == status && item.dig("payload", "turn_public_id") == turn_id
        end
      end
    end

    # The loop backing a turn, off the feed.
    def loop_for_turn(conversation, turn_id)
      await_feed(conversation, "no loop ever backed the turn #{turn_id}") do |items|
        items.find { |item| item["type"] == "turn_status" && item.dig("payload", "turn_public_id") == turn_id }
      end.dig("payload", "run_public_id")
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

    # The MEMBER plane, as the person who owns the work. UTF-8 by name.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      warn_text(File.read(path, encoding: Encoding::UTF_8), "#{label} (#{path})")
    end

    def warn_text(text, label)
      return if text.to_s.empty?

      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(text.scrub.lines.last(LOG_TAIL_LINES).join)}"
    end
end
