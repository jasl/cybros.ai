require "support/daemon_run_helpers"

class DaemonConversationModesTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  class CapturedApi < NexusDoubles::FakeAgentApi
    private

      def conversation_row(public_id, side: false)
        super.merge("agent_configuration_present" => true)
      end

      def tool_assembly_response(body)
        return super unless body.key?("conversation_public_id")

        @tool_assemblies << body
        definitions = @tools.map { |entry| entry.fetch("definition") }
        respond(200, { "tool_definitions" => definitions, "environment" => {} })
      end
  end

  def test_subagent_off_narrows_a_captured_child_after_the_live_kernel_selection_is_cleared
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG,
      trace: NexusDoubles::RUNNING_TRACE, events: [])
    daemon = member_ready(boot(config: catalog_config("kernel_tools" => []), realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("child-1"), workspace: "ws-1", model: "dev/model", subagent: false)
    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "child-1", text: "Continue", wait: false })
    assert_equal "200", response.code, response.body
    assert_equal [], api.inputs.last.dig("input", "tool_names")
    assert_equal "child-1", api.tool_assemblies.last.fetch("conversation_public_id")
  end

  def test_subagent_off_filters_kernel_and_alias_names_but_keeps_existing_work_controls
    names = { "nexus.graph.delegate_task" => "delegate_task", "nexus.conversation.spawn" => "spawn",
      "nexus.conversation.send" => "send", "nexus.conversation.status" => "status", "nexus.conversation.cancel" => "cancel" }
    tools = names.map do |canonical, name|
      { "canonical_name" => canonical, "name" => name, "effect_profile" => {},
        "definition" => { "type" => "function", "function" => { "name" => name,
          "description" => name, "parameters" => { "type" => "object", "properties" => {} } } } }
    end
    api = kernel_api(user_public_id: IDENTITY.user_public_id, tools: tools, events: [])
    daemon = member_ready(boot(config: catalog_config("kernel_tools" => names.keys), realtime_factory: ->(*) { nil }), api)
    _, opened = open(daemon, subagent: false)
    id = opened.dig("conversation", "public_id")
    body = { public_id: id, text: "Continue", model: "dev/model", wait: false }
    response = request(daemon, :post, "/say", token: bearer(daemon), body: body)
    assert_equal "200", response.code, response.body
    input = api.inputs.last.fetch("input")
    declared = api.tool_assemblies.last.fetch("configuration")
    spawn = declared.fetch("tool_definitions").find { |entry| entry["canonical"] == "nexus.conversation.spawn" }.dig("function", "name")
    refute_includes input.fetch("tool_names"), spawn
    refute_includes input.fetch("tool_names"), "delegate_task"
    %w[send status cancel].each { |name| assert_includes input.fetch("tool_names"), name }

    response = request(daemon, :post, "/say", token: bearer(daemon), body: body.merge(tool_names: [spawn, "delegate_task", "send"]))
    assert_equal "200", response.code, response.body
    assert_equal ["send"], api.inputs.last.dig("input", "tool_names")
    response = request(daemon, :patch, "/conversations/modes", token: bearer(daemon), body: { public_id: id, subagent: true })
    assert_equal "200", response.code, response.body
    assert_equal true, JSON.parse(response.body).dig("modes", "code_mode"), "editing one mode preserves the other"
    response = request(daemon, :post, "/say", token: bearer(daemon), body: body.merge(tool_names: [spawn, "delegate_task", "send"]))
    assert_equal "200", response.code, response.body
    assert_equal [spawn, "delegate_task", "send"], api.inputs.last.dig("input", "tool_names")
    refute_includes input.fetch("tool_names"), spawn, "changing modes does not rewrite accepted input"
  end

  def test_modes_reject_null_and_sides_inherit_both_choices
    api = kernel_api(user_public_id: IDENTITY.user_public_id, events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    _, opened = open(daemon, code_mode: false, subagent: false)
    id = opened.dig("conversation", "public_id")
    response = request(daemon, :post, "/side", token: bearer(daemon), body: { parent_public_id: id })
    assert_equal "201", response.code, response.body
    side = host_store(daemon).find(JSON.parse(response.body).dig("side", "public_id"))
    assert_equal false, side.code_mode
    assert_equal false, side.subagent

    %w[code_mode subagent].each do |key|
      response = request(daemon, :patch, "/conversations/modes", token: bearer(daemon), body: { public_id: id, key => nil })
      assert_equal "400", response.code, response.body
      response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "No reset", key => nil })
      assert_equal "400", response.code, response.body
      status, = open(daemon, key => nil)
      assert_equal "400", status
    end
    assert_empty api.inputs
  end

  def test_historical_missing_policy_uses_fixed_initial_values_and_never_global_defaults
    api = kernel_api(user_public_id: IDENTITY.user_public_id, events: [])
    daemon = member_ready(boot(config: catalog_config("subagent_default" => false,
      "plugins" => { "rho.codemode" => { "configuration_version" => 1, "configuration" => { "default" => "off" } } }),
      realtime_factory: ->(*) { nil }), api)
    response = request(daemon, :get, "/conversations/modes?public_id=old-conversation", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal true, JSON.parse(response.body).dig("modes", "code_mode")
    assert_equal true, JSON.parse(response.body).dig("modes", "subagent")
    response = request(daemon, :get, "/settings/status", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    seeds = JSON.parse(response.body).dig("defaults", "conversation_modes")
    assert_equal false, seeds.fetch("code_mode")
    assert_equal false, seeds.fetch("subagent")
  end
end
