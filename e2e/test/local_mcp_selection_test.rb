require "test_helper"
require "support/mcp_fixture/journey"

# The same local sources cross the external Bot and captured-role boundaries.
# Preset exclusions change future inputs while old runs retain their exact routes.
class LocalMcpSelectionTest < Minitest::Test
  include E2E::McpFixture::Journey

  def test_external_bots_use_local_mcp_by_default_and_presets_narrow_future_inputs_and_children
    connect!
    preset = create_preset("Local services", tools: ["nexus.conversation.spawn"])
    assert_equal({ "disabled_connections" => [], "disabled_tools" => [] }, preset.dig("configuration", "mcp"))
    bot = create_bot(preset)
    chat = bot_conversation(bot)
    assert_equal bot.fetch("public_id"), chat.fetch.answering_user_public_id
    refute_equal @member.profile.fetch.member.public_id, bot.fetch("public_id")

    baseline = say(chat, [
      directive("echo", "text" => "External stdio"),
      directive("echo", { "text" => "External HTTP" }, server: REMOTE),
    ], reply: "external-defaults")
    assert_echo(baseline, server: SERVER, text: "External stdio")
    assert_echo(baseline, server: REMOTE, text: "External HTTP")
    baseline_tools = declarations(baseline)
    all_mcp = [SERVER, REMOTE].flat_map { |server| mcp_connection(server).fetch("tools").map { |tool| tool.fetch("callable_name") } }
    assert_equal all_mcp.sort, mcp_names(baseline_tools)
    refute_includes baseline_tools.map { |tool| tool.dig("function", "name") }, "read"
    refute_includes baseline_tools.map { |tool| tool.dig("function", "name") }, "code"
    bindings = chat.turns.fetch(baseline.turn_public_id).active_variant.memory_context.fetch("bindings")
    assert_equal %w[conversation speaker workspace], bindings.map { |binding| binding.fetch("name") }.sort

    replace_preset(preset, mcp: exclusions(tools: [mcp_ref(SERVER).merge("tool_name" => "echo")]))
    before = @daemon.claims.length
    narrowed = say(chat, [
      directive("echo", "text" => "Disabled stdio"),
      directive("paths", "paths" => ["/tmp/one", "/tmp/two"]),
      directive("echo", { "text" => "HTTP still available" }, server: REMOTE),
    ], reply: "one-tool-disabled")
    assert_unknown(narrowed, mcp_callable("echo"))
    assert_equal "2 paths", output_for(narrowed, "mcp__fx__paths").strip
    assert_echo(narrowed, server: REMOTE, text: "HTTP still available")
    assert_equal all_mcp.sort - [mcp_callable("echo")], mcp_names(declarations(narrowed))
    assert_equal before + 2, @daemon.claims.length, "the disabled callable never reaches either executor"
    assert_equal baseline_tools, declarations(baseline), "a Preset edit does not rewrite an accepted surface"

    replace_preset(preset, mcp: exclusions(connections: [mcp_ref(SERVER)]))
    before = @daemon.claims.length
    disconnected = say(chat, [
      directive("paths", "paths" => ["/tmp/disabled"]),
      directive("echo", { "text" => "HTTP after connection exclusion" }, server: REMOTE),
    ], reply: "one-connection-disabled")
    assert_unknown(disconnected, mcp_callable("paths"))
    assert_echo(disconnected, server: REMOTE, text: "HTTP after connection exclusion")
    assert_equal mcp_connection(REMOTE).fetch("tools").map { |tool| tool.fetch("callable_name") }.sort,
      mcp_names(declarations(disconnected))
    assert_equal before + 1, @daemon.claims.length, "excluding stdio leaves the independent HTTP source usable"

    # Parent and role each remove a different tool; the role also removes HTTP.
    # The child still executes stdio under the same external Bot principal.
    replace_preset(preset, mcp: exclusions(tools: [mcp_ref(SERVER).merge("tool_name" => "paths")]))
    role = create_preset("Local narrowed worker", mcp: exclusions(connections: [mcp_ref(REMOTE)],
      tools: [mcp_ref(SERVER).merge("tool_name" => "lookup")]))
    control(:put, "/presets/role", public_id: role.fetch("public_id"), name: "local-child", description: "Use inherited local tools for one task.")
    identities = @member.workspace(@workspace_public_id).principals.map(&:public_id).sort
    child_prompt = script([
      directive("echo", "text" => "Child stdio"),
      directive("lookup", "key" => "excluded-by-role"),
      directive("paths", "paths" => ["/tmp/excluded-by-parent"]),
      directive("echo", { "text" => "Excluded HTTP" }, server: REMOTE),
    ], reply: "local-child-finished")
    parent = say(chat, [
      directive("echo", { "text" => "Parent HTTP" }, server: REMOTE),
      "spawn:#{CGI.escape(JSON.generate("role" => "local-child", "prompt" => child_prompt, "label" => "local-child", "wait" => true))}",
    ], reply: "local-parent-finished")
    assert_echo(parent, server: REMOTE, text: "Parent HTTP")
    child_chat, child = child_result(chat, label: "local-child", reply: "local-child-finished")
    assert_equal bot.fetch("public_id"), child_chat.fetch.answering_user_public_id
    assert_echo(child, server: SERVER, text: "Child stdio")
    [mcp_callable("lookup"), mcp_callable("paths"), mcp_callable("echo", server: REMOTE)].each { |name| assert_unknown(child, name) }
    child_tools = declarations(child)
    assert_equal %w[echo exit hang].map { |name| mcp_callable(name) }.sort, mcp_names(child_tools)
    inherited_echo = declarations(parent).find { |tool| tool.dig("function", "name") == mcp_callable("echo") }
    assert_includes child_tools, inherited_echo, "the child's schema and Runner target are the parent's captured bytes"
    assert_equal ["conversation"], child_chat.turns.fetch(child.turn_public_id).active_variant.memory_context.fetch("bindings")
      .map { |binding| binding.fetch("name") }
    assert_equal identities, @member.workspace(@workspace_public_id).principals.map(&:public_id).sort,
      "a role execution creates no persistent Agent identity"
  end

  private

    def create_preset(name, **configuration)
      response = control(:post, "/presets", name: name, description: "Local MCP execution coverage.", configuration: {
        model: MODEL, tools: [], runner_tool_names: [], approval_mode: "bypass",
        system_prompt: "Use the selected service and return its result.",
      }.merge(configuration))
      response.fetch("presets").find { |entry| entry.fetch("name") == name } || flunk("the created Preset was absent")
    end

    def replace_preset(preset, **configuration)
      current = control(:get, "/presets").fetch("presets").find { |entry| entry.fetch("public_id") == preset.fetch("public_id") }
      refute_nil current
      control(:put, "/presets", **current.slice("public_id", "name", "description").transform_keys(&:to_sym),
        configuration: current.fetch("configuration").merge(configuration.transform_keys(&:to_s)))
    end

    def exclusions(connections: [], tools: [])
      { "disabled_connections" => connections, "disabled_tools" => tools }
    end

    def create_bot(preset)
      bot = control(:put, "/agents", name: "external-local-mcp", display_name: "External local services",
        description: "Uses its selected local MCP services.", preset_public_id: preset.fetch("public_id"),
        audience: "external", subagent: true).fetch("agent")
      control(:put, "/agents/settings", agent_public_id: bot.fetch("public_id"), home_workspace_public_id: @workspace_public_id)
      bot
    end

    def bot_conversation(bot)
      current = control(:post, "/bots/current", agent_public_id: bot.fetch("public_id"), operation_id: SecureRandom.uuid).fetch("current")
      @member.workspace(@workspace_public_id).conversation(current.fetch("public_id"))
    end

    def script(calls, reply:)
      "!mock tool_call=#{calls.join(",")} reply=#{CGI.escape(reply)} -- Use the selected local service."
    end

    def say(chat, calls, reply:)
      # The mock indexes calls by every tool answer in the conversation history.
      # Keep that completed prefix so each new input starts with its own calls.
      @scripted_calls ||= Hash.new { |scripts, public_id| scripts[public_id] = [] }
      scripted_calls = @scripted_calls[chat.public_id].concat(calls)
      accepted = control(:post, "/say", public_id: chat.public_id, text: script(scripted_calls, reply: reply), wait: false)
      input_id = accepted.fetch("input").fetch("public_id")
      materialization = @daemon.await("the accepted input never materialized") do
        row = chat.inputs.materialization(input_id)
        row if row&.run_public_id
      end
      assert_equal input_id, materialization.input_public_id
      await_run_status(materialization.run_public_id, "completed")
      assert_reply(chat, materialization, reply)
      materialization
    end

    def child_result(parent, label:, reply:)
      child = @daemon.await("the local role never created its child") { parent.children.items.find { |entry| entry.parent&.label == label } }
      chat = @member.workspace(@workspace_public_id).conversation(child.public_id)
      turn = @daemon.await("the local child never completed") do
        chat.turns.list.items.find { |entry| entry.role == "assistant" && entry.status == "completed" && entry.text == "Mock: #{reply}" }
      end
      materialization = chat.inputs.materialization(turn.input_public_id)
      assert_equal turn.public_id, materialization.turn_public_id
      await_run_status(materialization.run_public_id, "completed")
      assert_reply(chat, materialization, reply)
      [chat, materialization]
    end

    def assert_reply(chat, materialization, text)
      turn = @daemon.await("the accepted turn never completed") do
        row = chat.turns.fetch(materialization.turn_public_id)
        row if row.status == "completed"
      end
      assert_equal "Mock: #{text}", turn.text
      assert_equal materialization.input_public_id, turn.input_public_id
      assert_equal materialization.run_public_id, turn.active_variant.run_public_id
      assert_equal materialization, chat.inputs.materialization(materialization.input_public_id)
    end

    def declarations(materialization) = @loops.run(materialization.run_public_id).task("r1").tool_definitions

    def mcp_names(tools)
      tools.filter_map { |tool| tool.dig("function", "name") if tool.dig("function", "name").start_with?("mcp__") }.sort
    end

    def task_for(materialization, name)
      run = loop_row(materialization.run_public_id)
      row = run.fetch("tasks").find { |task| task["tool_name"] == name }
      refute_nil row, "#{name} was never called: #{summarize(run)}"
      row
    end

    def output_for(materialization, name)
      row = task_for(materialization, name)
      assert_equal "completed", row.fetch("status"), row.inspect
      task_output(materialization.run_public_id, row.fetch("key"))
    end

    def assert_echo(materialization, server:, text:)
      served = "mcp__#{server}__echo"
      row = task_for(materialization, served)
      assert_equal "completed", row.fetch("status"), row.inspect
      assert_equal server == SERVER ? "runner" : "agent", row.dig("addressed_to", "role")
      assert_equal mcp_ref(server).fetch("executor_public_id"), row.dig("addressed_to", "executor_public_id")
      detail = task_detail(materialization.run_public_id, row.fetch("key"))
      assert_equal({ "text" => text }, detail.fetch("tool_input"))
      assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}#{text}", detail.fetch("output").strip
      if server == SERVER
        assert_equal mcp_callable("echo"), row.fetch("tool_alias")
      end
    end

    def assert_unknown(materialization, name)
      row = task_for(materialization, name)
      assert_equal "failed", row.fetch("status"), row.inspect
      assert_equal "unknown_tool", row.dig("error", "key"), row.inspect
      assert_nil row["addressed_to"], "a missing declaration cannot reach an executor"
    end

    def control(method, path, **body)
      @daemon.control(method, path, body: body, expected_status: 200)
    end
end
