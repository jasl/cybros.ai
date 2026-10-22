require "test_helper"
require "cgi/escape"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/steward_session"
require "support/mcp_fixture/declarations"

# One Human connects a service for Main, Bots and their narrowed Subagents.
# All configuration, inputs, approvals and results use public doors.
class NexusMcpTest < Minitest::Test
  MODEL = E2E::CatalogOverlay::MCP_MODEL
  WAIT = E2E::RhoDaemon::WATCH_TIMEOUT

  def setup
    @base_url = E2E.base_url(mcp_fixture: true)
    @fixture_url = E2E.handle.fetch("mcp_fixture_url")
    refute_nil @fixture_url, "this journey needs its world-owned MCP fixture"
    @steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    E2E::SessionSignInBudget.consume
    grant = CybrosAgent::Platform::Sessions.new(base_url: @base_url).create(email: @steward.email, password: @steward.password)
    E2E::SecretHygiene.register(grant.token)
    @operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
    @home = Dir.mktmpdir("rho-nexus-mcp-e2e")
    @artifacts = File.expand_path("../artifacts/nexus_mcp/#{name}-#{Process.pid}", __dir__)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    File.write(File.join(@home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(
      default_model: MODEL, webui_access: "open", subagent_default: false)), perm: 0o600)
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @workspace_id = @daemon.await("rho workspace adoption") do
      status = @daemon.status
      status.dig("workspace", "public_id") if status.dig("workspace", "state") == "adopted"
    end
    @daemon.await_announced(address: "agent")
    @daemon.await_announced(address: "runner")
    @member = @daemon.member_client
    @main_id = @member.profile.fetch.member.public_id
    E2E.enable_dev_lane!
    E2E.hosts.start
  end

  def teardown
    if @browser
      FileUtils.mkdir_p(@artifacts)
      File.write(File.join(@artifacts, "browser-console.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(@browser.console_logs)))
      unless passed?
        E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "failure.png"))
        File.write(File.join(@artifacts, "page.html"), E2E::SecretHygiene.redact(@page.html))
      end
    end
    unless passed?
      [@daemon&.log_path, @daemon&.rho_log_path].compact.each do |path|
        warn E2E::SecretHygiene.redact(File.read(path).lines.last(100).join) if File.file?(path)
      end
      %i[jobs runner].each do |host|
        path = E2E.hosts.log_path(host)
        warn E2E::SecretHygiene.redact(File.read(path).lines.last(80).join) if File.file?(path)
      end
    end
    if @connection
      current = @operator.mcp_connections.fetch(@connection.public_id)
      @operator.mcp_connections.update(current.public_id, lock_version: current.lock_version, enabled: false)
    end
    @operator&.session&.revoke
  ensure
    @browser&.close
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_main_and_bots_use_owned_connections_by_default_and_presets_can_turn_off_tools_or_connections
    create_connection
    preset = create_preset
    control(:put, "/presets/defaults", main_preset_public_id: preset.fetch("public_id"))
    assert_equal({ "disabled_connections" => [], "disabled_tools" => [] }, preset.dig("configuration", "mcp"))
    visit_console
    open_preset(preset)
    assert @page.has_checked_field?("Use #{@connection.name}", visible: :all, wait: WAIT)
    assert @page.has_checked_field?("Use echo from #{@connection.name}", visible: :all, wait: WAIT)
    assert @page.has_no_field?("Callable name for echo")
    assert @page.has_link?("Manage MCP connections in Nexus", href: "#{@base_url}/settings/mcp_connections")
    screenshot("default-tools-desktop")
    @browser.resize(390, 844)
    screenshot("default-tools-narrow")
    @browser.resize(1400, 1000)
    main = cli_turn(script("Main account", reply: "main-finished"))
    complete_call(main, text: "Main account", reply: "main-finished")
    assert_equal @connection.tools.map { |tool| tool.fetch("name") }.sort,
      @member.profile.fetch.configuration.mcp_tools.map { |tool| tool.fetch("tool_name") }.sort

    bot = create_bot(preset, name: "cloud-helper", audience: "owner")
    bot_id = bot.fetch("public_id")
    refute_equal @main_id, bot_id
    assert_equal connection_choices(@main_id), connection_choices(bot_id)
    current = bot_current(bot_id)
    conversation = @member.workspace(@workspace_id).conversation(current.fetch("public_id"))
    bot_answer = control(:post, "/say", public_id: current.fetch("public_id"),
      text: script("Bot account", reply: "bot-finished"), wait: false)
    complete_call(accepted_turn(bot_answer, conversation), text: "Bot account", reply: "bot-finished")
    assert_equal bot_id, conversation.fetch.answering_user_public_id

    external_preset = create_preset(name: "External cloud tools")
    external = create_bot(external_preset, name: "external-cloud-helper", audience: "external")
    assert_equal connection_choices(@main_id), connection_choices(external.fetch("public_id"))

    # An individual exclusion keeps the connection and its other tools available.
    reopen_preset(preset)
    @page.uncheck "Use echo from #{@connection.name}", allow_label_click: true
    save_preset
    assert @page.has_checked_field?("Use #{@connection.name}", visible: :all, wait: WAIT)
    assert @page.has_unchecked_field?("Use echo from #{@connection.name}", visible: :all, wait: WAIT)
    assert @page.has_checked_field?("Use write from #{@connection.name}", visible: :all, wait: WAIT)
    assert_equal({ "disabled_connections" => [], "disabled_tools" => [connection_ref.merge("tool_name" => "echo")] },
      saved_preset(preset).dig("configuration", "mcp"))
    remaining = bot_current(bot_id, fresh: true)
    remaining_chat = @member.workspace(@workspace_id).conversation(remaining.fetch("public_id"))
    answer = control(:post, "/say", public_id: remaining.fetch("public_id"), text: "!mock reply=tool-disabled -- Answer without echo", wait: false)
    remaining_turn = accepted_turn(answer, remaining_chat)
    await_completed(remaining_turn.fetch(:run))
    names = remaining_turn.fetch(:run).task("r1").tool_definitions.map { |tool| tool.dig("function", "name") }
    assert_equal (@callables.values - [@callables.fetch("echo")]).sort, names.sort
    assert_history(remaining_turn, "tool-disabled")

    # Turning off the connection removes every tool for future inputs while an
    # independently configured Bot under the same Human keeps its own choice.
    reopen_preset(preset)
    @page.uncheck "Use #{@connection.name}", allow_label_click: true
    save_preset
    assert @page.has_unchecked_field?("Use #{@connection.name}", visible: :all, wait: WAIT)
    assert @page.has_field?("Use echo from #{@connection.name}", disabled: true, visible: :all)
    assert_equal [connection_ref], saved_preset(preset).dig("configuration", "mcp", "disabled_connections")
    screenshot("connection-disabled-desktop")
    fresh = bot_current(bot_id, fresh: true)
    fresh_conversation = @member.workspace(@workspace_id).conversation(fresh.fetch("public_id"))
    empty_answer = control(:post, "/say", public_id: fresh.fetch("public_id"), text: "!mock reply=connection-disabled -- Answer without tools", wait: false)
    empty_input_id = empty_answer.fetch("input").fetch("public_id")
    empty_materialization = @daemon.await("the tool-free input never materialized") { fresh_conversation.inputs.materialization(empty_input_id) }
    empty_reply = @daemon.await("the tool-free reply never completed") do
      row = fresh_conversation.turns.fetch(empty_materialization.turn_public_id)
      row if row.status == "completed"
    end
    assert_equal empty_input_id, empty_reply.input_public_id
    assert_nil empty_materialization.run_public_id, "no tools means the ordinary inference path, without a Run"
    assert_equal "inference", empty_reply.active_variant.source
    assert_includes empty_reply.text, "Mock: connection-disabled"
    assert_empty @member.tools.assemble(agent_public_id: bot_id).tool_definitions
    assert_includes connection_choices(bot_id), connection_ref
    assert_empty @member.profile.agents.list.find { |row| row.public_id == bot_id }.configuration.mcp_tools
    assert_history({ conversation: fresh_conversation, turn: empty_materialization.turn_public_id, materialization: empty_materialization }, "connection-disabled")

    external_current = bot_current(external.fetch("public_id"))
    external_chat = @member.workspace(@workspace_id).conversation(external_current.fetch("public_id"))
    external_answer = control(:post, "/say", public_id: external_current.fetch("public_id"),
      text: script("External Bot account", reply: "external-finished"), wait: false)
    external_turn = accepted_turn(external_answer, external_chat)
    complete_call(external_turn, text: "External Bot account", reply: "external-finished")
    assert_equal external.fetch("public_id"), external_chat.fetch.answering_user_public_id
    bindings = external_chat.turns.fetch(external_turn.fetch(:turn)).active_variant.memory_context.fetch("bindings")
    assert_equal %w[conversation speaker workspace], bindings.map { |binding| binding.fetch("name") }.sort
    errors = @browser.console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
  end

  def test_subagents_inherit_the_parents_captured_mcp_tools_and_nested_roles_cannot_restore_exclusions
    create_connection
    parent = create_preset(name: "Parent cloud tools", tools: ["nexus.conversation.spawn"], approval_mode: "bypass",
      mcp: { disabled_connections: [], disabled_tools: [connection_ref.merge("tool_name" => "lookup")] })
    middle = create_preset(name: "Narrower cloud worker", tools: ["nexus.conversation.spawn"], approval_mode: "bypass",
      mcp: { disabled_connections: [], disabled_tools: [connection_ref.merge("tool_name" => "write")] })
    leaf = create_preset(name: "Default cloud worker", approval_mode: "bypass")
    control(:put, "/presets/role", public_id: middle.fetch("public_id"), name: "cloud-middle", description: "Use the narrower cloud tools and delegate a final check.")
    control(:put, "/presets/role", public_id: leaf.fetch("public_id"), name: "cloud-leaf", description: "Check the cloud account with inherited tools.")
    control(:put, "/presets/defaults", main_preset_public_id: parent.fetch("public_id"))
    identities = @member.workspace(@workspace_id).principals.map(&:public_id).sort

    leaf_prompt = script("Nested account", reply: "leaf-finished")
    middle_prompt = calls_script([
      [@callables.fetch("echo"), { "text" => "Child account" }],
      ["spawn", { "role" => "cloud-leaf", "prompt" => leaf_prompt, "label" => "cloud-leaf", "wait" => true }],
    ], reply: "middle-finished")
    prompt = calls_script([["spawn", { "role" => "cloud-middle", "prompt" => middle_prompt, "label" => "cloud-middle", "wait" => true }]],
      reply: "parent-finished")
    opened = @daemon.control(:post, "/conversations", expected_status: 201,
      body: { prompt: prompt, model: MODEL, code_mode: false, subagent: true })
    parent_chat = @member.workspace(@workspace_id).conversation(opened.fetch("conversation").fetch("public_id"))
    parent_turn = accepted_turn(opened, parent_chat)
    await_completed(parent_turn.fetch(:run))
    assert_history(parent_turn, "parent-finished")
    child = child_turn(parent_chat, label: "cloud-middle", reply: "middle-finished")
    grandchild = child_turn(child.fetch(:conversation), label: "cloud-leaf", reply: "leaf-finished")
    parent_tools = parent_turn.fetch(:run).task("r1").tool_definitions
    child_tools = child.fetch(:run).task("r1").tool_definitions
    grandchild_tools = grandchild.fetch(:run).task("r1").tool_definitions
    assert_equal (@callables.keys - ["lookup"]).sort, mcp_remote_names(parent_tools)
    assert_equal (@callables.keys - %w[lookup write]).sort, mcp_remote_names(child_tools)
    assert_equal mcp_remote_names(child_tools), mcp_remote_names(grandchild_tools), "the leaf's default-on Preset cannot restore its parent's omissions"
    echo = parent_tools.find { |tool| tool.dig("route", "tool_name") == "echo" }
    assert_includes child_tools, echo
    assert_includes grandchild_tools, echo
    [child, grandchild].zip(["Child account", "Nested account"]).each do |turn, text|
      row = turn.fetch(:run).fetch.tasks.find { |task| task.tool_name == "echo" }
      refute_nil row
      assert_equal "completed", row.status
      assert_equal @connection.public_id, row.target.connection_public_id
      assert_equal @callables.fetch("echo"), row.tool_alias
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}#{text}", turn.fetch(:run).task(row.key).output.strip
      assert_equal @main_id, turn.fetch(:conversation).fetch.answering_user_public_id
    end
    assert_equal identities, @member.workspace(@workspace_id).principals.map(&:public_id).sort, "Subagents create no persistent Agent identity"
  end

  def test_browser_oauth_connects_a_nexus_owned_tool_and_disconnect_cuts_new_use
    oauth_url = E2E.handle.fetch("mcp_oauth_fixture_url")
    connection_name = "OAuth cloud notes #{SecureRandom.hex(3)}"
    page = @actor.page
    @actor.visit("/settings/mcp_connections/new")
    page.fill_in "Name", with: connection_name
    page.fill_in "External account label", with: "Work"
    page.fill_in "Service URL", with: oauth_url
    page.select "OAuth browser sign-in", from: "Authentication"
    page.click_button "Create connection"
    assert page.has_text?("Authorize the service before discovering or calling tools.")
    connection_id = page.current_path.split("/").last
    @connection = @operator.mcp_connections.fetch(connection_id)
    assert_equal "not_authorized", @connection.authorization_status
    refute @connection.available

    page.click_button "Authorize service"
    assert page.has_text?("Service authorized. Discover its tools to make them available.", wait: WAIT)
    assert_equal "/settings/mcp_connections/#{connection_id}", page.current_path
    assert_nil URI(page.current_url).query, "the callback code is removed before ordinary rendering"
    @connection = @operator.mcp_connections.fetch(connection_id)
    assert_equal "authorized", @connection.authorization_status
    assert @connection.credential_configured
    refute_nil @connection.authorization_expires_at
    page.click_button "Discover tools"
    assert page.has_text?("Tool catalog refreshed.", wait: WAIT)
    assert page.has_text?("echo")
    @actor.resize(1400, 1000)
    E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "oauth-authorized-desktop.png"))
    @actor.resize(390, 844)
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "oauth-authorized-narrow.png"))
    @actor.resize(1400, 1000)
    @connection = @operator.mcp_connections.fetch(connection_id)
    load_connection_tools
    preset = create_preset(name: "Authorized cloud tools")
    control(:put, "/presets/defaults", main_preset_public_id: preset.fetch("public_id"))
    visit_console
    complete_call(cli_turn(script("OAuth account", reply: "oauth-finished")), text: "OAuth account", reply: "oauth-finished")

    @actor.visit("/settings/mcp_connections/#{connection_id}")
    page.click_button "Disconnect service"
    assert page.has_text?("Authorize the service before discovering or calling tools.", wait: WAIT)
    disconnected = @operator.mcp_connections.fetch(connection_id)
    assert_equal "not_authorized", disconnected.authorization_status
    refute disconnected.credential_configured
    refute disconnected.available
    row = @member.mcp_connections.fetch(connection_id)
    refute row.available
    refusal = assert_raises(CybrosAgent::Api::InvalidRequest) { @member.tools.assemble }
    assert_equal "mcp_connection_unavailable", refusal.code,
      "cleared OAuth authority cannot enter a new tool declaration"
  end

  private

    def create_connection
      connections = @operator.mcp_connections
      @connection = connections.create(name: "E2E cloud notes #{SecureRandom.hex(3)}", endpoint_url: @fixture_url, auth_type: "none", account_label: "Work")
      @connection = connections.refresh_catalog(@connection.public_id, lock_version: @connection.lock_version)
      load_connection_tools
    end

    def load_connection_tools
      directory = @daemon.control(:get, "/presets/tools", expected_status: 200).fetch("mcp_connections")
      row = directory.find { |entry| entry.fetch("ref") == connection_ref }
      refute_nil row
      assert row.fetch("available")
      @callables = row.fetch("tools").to_h { |tool| [tool.fetch("name"), tool.fetch("callable_name")] }
      assert_equal @connection.tools.map { |tool| tool.fetch("name") }.sort, @callables.keys.sort
      assert_includes @callables.keys, "echo"
    end

    def connection_ref = { "source" => "nexus", "connection_public_id" => @connection.public_id }

    def create_preset(name: "Cloud tools", **configuration)
      rows = control(:post, "/presets", name: name, description: "Cloud service configuration.", configuration: {
        model: MODEL, system_prompt: "Use the available service when requested.",
        tools: [], runner_tool_names: [], approval_mode: "ask",
      }.merge(configuration)).fetch("presets")
      rows.find { |row| row.fetch("name") == name } || flunk("created Preset was absent")
    end

    def saved_preset(preset)
      control(:get, "/presets").fetch("presets").find { |row| row.fetch("public_id") == preset.fetch("public_id") } || flunk("saved Preset was absent")
    end

    def create_bot(preset, name:, audience:)
      bot = control(:put, "/agents", name: name, display_name: name, description: "Uses its Human's cloud account.",
        preset_public_id: preset.fetch("public_id"), audience: audience, subagent: false).fetch("agent")
      control(:put, "/agents/settings", agent_public_id: bot.fetch("public_id"), home_workspace_public_id: @workspace_id)
      bot
    end

    def bot_current(agent_id, fresh: false)
      control(:post, fresh ? "/bots/new" : "/bots/current", agent_public_id: agent_id, operation_id: SecureRandom.uuid).fetch("current")
    end

    def connection_choices(agent_id)
      @member.mcp_connections.list(agent_public_id: agent_id, limit: 100).items.map do |row|
        { "source" => "nexus", "connection_public_id" => row.public_id }
      end
    end

    def child_turn(parent, label:, reply:)
      child = @daemon.await("the #{label} child was never created") { parent.children.items.find { |row| row.parent&.label == label } }
      conversation = @member.workspace(@workspace_id).conversation(child.public_id)
      turn = @daemon.await("the #{label} child never completed its reply") do
        conversation.turns.list.items.find { |row| row.role == "assistant" && row.status == "completed" && row.text.include?("Mock: #{reply}") }
      end
      materialization = conversation.inputs.materialization(turn.input_public_id)
      assert_equal turn.public_id, materialization.turn_public_id
      result = { conversation: conversation, turn: turn.public_id, materialization: materialization,
        run: @member.workspace(@workspace_id).runs.run(materialization.run_public_id) }
      assert_history(result, reply)
      result
    end

    def mcp_remote_names(tools)
      tools.select { |tool| tool.dig("route", "kind") == "mcp" }.map { |tool| tool.dig("route", "tool_name") }.sort
    end

    def control(method, path, **body)
      @daemon.control(method, path, body: body, expected_status: 200)
    end

    def visit_console
      url = cli("console")[/^console:\s+(\S+)/, 1]
      refute_nil url
      @browser = E2E::BrowserActor.new(url)
      @page = @browser.page
      @browser.resize(1400, 1000)
      @browser.visit(url)
      assert @page.has_field?("Message", wait: WAIT)
    end

    def open_preset(preset)
      @page.click_link "Settings", exact: true
      @page.click_button "Agent Presets", exact: true
      @page.within(%(article[data-preset="#{preset.fetch("public_id")}"])) do
        @page.find(".preset-catalog__name").click
      end
      assert @page.has_field?("Use #{@connection.name}", visible: :all, wait: WAIT)
    end

    def reopen_preset(preset)
      @page.refresh
      open_preset(preset)
    end

    def save_preset
      @page.within(".preset-editor") { @page.click_button "Save", exact: true }
      assert @page.has_text?("Preset settings saved.", wait: WAIT)
      @page.within(".preset-editor") { assert @page.has_button?("Save", exact: true, disabled: false, wait: WAIT) }
    end

    def screenshot(name, focus: ".mcp-tool-picker [data-mcp-connection='nexus:#{@connection.public_id}']")
      assert @page.has_no_css?(".toast", wait: WAIT)
      @page.find(".page").scroll_to(@page.find(focus), align: :top) if focus
      assert @page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "the page fits the viewport"
      E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "#{name}.png"))
    end

    def script(text, reply:)
      calls_script([[@callables.fetch("echo"), { "text" => text }]], reply: reply)
    end

    def calls_script(calls, reply:)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      "!mock tool_call=#{spelled.join(",")} reply=#{CGI.escape(reply)} -- Use the available cloud account"
    end

    def cli(*args)
      output, status = @daemon.cli(*args)
      assert_predicate status, :success?, output
      output
    end

    def cli_turn(prompt)
      output = cli("do", prompt, "--model", MODEL, "--code-mode=false")
      conversation_id, turn_id, run_id = %w[conversation turn run].map { |field| output[/^#{field}:\s+(\S+)/, 1] }
      refute_includes [conversation_id, turn_id, run_id], nil, output
      conversation = @member.workspace(@workspace_id).conversation(conversation_id)
      turn = conversation.turns.fetch(turn_id)
      materialization = conversation.inputs.materialization(turn.input_public_id)
      assert_equal [turn_id, run_id], [materialization.turn_public_id, materialization.run_public_id]
      { conversation: conversation, turn: turn_id, materialization: materialization,
        run: @member.workspace(@workspace_id).runs.run(run_id) }
    end

    def accepted_turn(answer, conversation)
      input_id = answer.fetch("input").fetch("public_id")
      materialization = @daemon.await("the accepted input never materialized into a Run") do
        row = conversation.inputs.materialization(input_id)
        row if row&.run_public_id
      end
      assert_equal input_id, materialization.input_public_id
      { conversation: conversation, turn: materialization.turn_public_id, materialization: materialization,
        run: @member.workspace(@workspace_id).runs.run(materialization.run_public_id) }
    end

    def complete_call(turn, text:, reply:)
      run = turn.fetch(:run)
      held = @daemon.await("the MCP call never requested approval") do
        row = run.fetch
        refute_equal "failed", row.status, row.to_h.inspect
        row.tasks.find { |task| task.status == "needs_approval" }
      end
      detail = run.task(held.key)
      assert_equal ["mcp", @connection.public_id, "echo"],
        [detail.task.target.kind, detail.task.target.connection_public_id, detail.task.target.tool_name]
      assert_equal "agent", detail.task.addressed_to.role, "the application receives the approval notice"
      assert_equal({ "text" => text }, detail.tool_input)
      assert_equal @callables.values.sort, run.task("r1").tool_definitions.map { |tool| tool.dig("function", "name") }.sort
      @browser.visit("/workspaces/#{@workspace_id}/conversations/#{turn.fetch(:conversation).public_id}")
      @page.within(".ask--approval", wait: WAIT) do
        assert @page.has_css?(".ask__headline", text: @callables.fetch("echo"), exact_text: true)
        assert @page.has_css?(".mcp-target", text: @connection.name)
        assert @page.has_css?(".mcp-target", text: "Work")
        assert @page.has_css?(".mcp-target", text: "echo")
      end
      screenshot("#{reply}-approval-desktop", focus: nil)
      @browser.resize(390, 844)
      screenshot("#{reply}-approval-narrow", focus: nil)
      @browser.resize(1400, 1000)
      assert_includes cli("approve", run.run_public_id, held.key), held.key
      await_completed(run)
      completed = run.task(held.key)
      assert_nil completed.task.addressed_to, "Nexus executes the approved call without an executor delivery"
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}#{text}", completed.output.strip
      assert_history(turn, reply)
      assert_equal turn.fetch(:materialization), turn.fetch(:conversation).inputs.materialization(turn.fetch(:materialization).input_public_id)
    end

    def await_completed(run)
      @daemon.await("the exact Run never completed") do
        row = run.fetch
        refute_includes %w[failed needs_attention], row.status, row.to_h.inspect
        row if row.status == "completed"
      end
    end

    def assert_history(turn, reply)
      history = @daemon.await("the exact turn never reached completed history") do
        page = turn.fetch(:conversation).history.list(around_turn_public_id: turn.fetch(:turn), include_execution: true)
        row = page.turns.find { |item| item.public_id == turn.fetch(:turn) }
        page if row&.status == "completed"
      end
      if (run_id = turn.fetch(:materialization).run_public_id)
        assert_equal run_id, history.execution.run_public_id
      else
        assert_nil history.execution
      end
      assert_includes JSON.generate(history.to_h), "Mock: #{reply}"
    end
end
