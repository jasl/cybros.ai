require "test_helper"
require "rho/bot_policy"

class BotPolicyTest < Minitest::Test
  TARGET = CybrosAgent::Api::NamedAgent.new(**{
    public_id: "019b1000-0000-7000-8000-000000000001", handle: "helper", name: "helper", kind: "agent",
    display_name: "Helper", agent_identifier: "rho.test/helper", steward_public_id: "owner", scope: "steward",
    description: "Answers questions.", derived_from_public_id: "rho", system_prompt: nil, summarizer: nil, configuration: nil,
  }).freeze
  ROLES = [
    { "name" => "worker", "description" => "Execute the supplied task." },
    { "name" => "reviewer", "description" => "Review a completed change." },
  ].freeze
  WIRES = {
    "nexus.memory.read" => "memory_read", "nexus.memory.write" => "memory_write",
    "nexus.conversation.spawn" => "spawn", "nexus.conversation.send" => "send_message",
    "nexus.tools.search" => "tool_search", "nexus.runners.list" => "runners_list",
    "nexus.models.list" => "models_list",
  }.freeze

  def configuration
    {
      kernel_tools: WIRES.keys - ["nexus.conversation.send"],
      tool_definitions: [
        { "type" => "function", "function" => { "name" => "send_message" }, "canonical" => "nexus.conversation.send",
          "params" => { "target" => { "maps_to" => "to" } }, "omit" => ["agent"], "description" => "Send a message." },
        { "type" => "function", "function" => { "name" => "mcp__private__read" } },
      ],
      runner_executor_public_ids: ["private-runner"], runner_tool_names: nil,
      mcp_tools: [{ "connection_public_id" => "019b1000-0000-7000-8000-000000000003", "tool_name" => "read", "name" => "private_read" }],
      approval_mode: "bypass", approval_rules: [{ "tool" => "*", "verdict" => "allow" }],
      prompt_template: nil, prompt_mechanism: "default", memory_context_limit: nil,
    }
  end

  def test_conversation_modes_narrow_only_the_bot_root_and_preserve_worker_and_approval_policy
    spawn = { "type" => "function", "function" => { "name" => "Worker" }, "canonical" => "nexus.conversation.spawn" }
    code = { "type" => "function", "function" => { "name" => "Code" }, "route" => { "tool_name" => "code" } }
    original = configuration.merge(kernel_tools: ["nexus.graph.delegate_task", "nexus.conversation.request", "nexus.conversation.status"],
      tool_definitions: configuration.fetch(:tool_definitions) + [spawn, code], system_prompt: { "content" => "Help the person." })
    original[:delegation_catalog] = [{ "name" => "worker", "declaration" => { "tool_definitions" => [code], "runner_tool_names" => ["code"],
      "kernel_tools" => ["nexus.graph.delegate_task"] } }]
    before = Marshal.dump(original)
    result = Rho::BotPolicy.conversation(original, subagent: false, runner_names: %w[read code shell])
    assert_equal ["nexus.conversation.status"], result.fetch(:kernel_tools)
    assert_equal %w[send_message mcp__private__read], result.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }
    assert_equal %w[read shell], result.fetch(:runner_tool_names)
    assert_equal original.fetch(:delegation_catalog), result.fetch(:delegation_catalog)
    assert_equal original.fetch(:approval_rules), result.fetch(:approval_rules)
    assert_equal original.fetch(:approval_mode), result.fetch(:approval_mode)
    assert_equal original.fetch(:mcp_tools), result.fetch(:mcp_tools)
    assert_includes result.dig(:system_prompt, "content"), "carry out the person's work directly"
    assert_equal before, Marshal.dump(original)
    enabled = Rho::BotPolicy.conversation(original.merge(runner_tool_names: ["read"]), subagent: true, runner_names: %w[read code shell])
    assert_equal ["read"], enabled.fetch(:runner_tool_names)
    assert_equal original.fetch(:kernel_tools), enabled.fetch(:kernel_tools)
    assert_includes enabled.fetch(:tool_definitions), spawn
    refute_includes enabled.fetch(:tool_definitions), code
    refute_includes enabled.dig(:system_prompt, "content"), "Subagent is off"
  end

  def test_requests_keep_the_same_exact_bot_target_boundary
    original = configuration.merge(kernel_tools: ["nexus.conversation.request"])
    wires = WIRES.merge("nexus.conversation.request" => "request")
    result = Rho::BotPolicy.external(original, send_targets: [TARGET], spawn_roles: [], wire_names: wires)
    assert_empty result.fetch(:kernel_tools)
    request = result.fetch(:tool_definitions).find { |entry| entry["canonical"] == "nexus.conversation.request" }
    assert_includes request.dig("params", "agent", "description"), TARGET.public_id
    assert_includes result.fetch(:approval_rules),
      { "tool" => "request", "path" => "agent", "match" => TARGET.public_id, "verdict" => "allow" }
    refute result.fetch(:approval_rules).any? { |rule| rule["tool"] == "request" && rule["path"] == "link_public_id" }
    assert_equal "subtree", result.fetch(:conversation_reach)
    assert_equal Rho::BotPolicy::MEMORY_CONTEXT_LIMIT, result.fetch(:memory_context_limit)
  end

  def test_external_policy_separates_spawn_roles_from_exact_bot_send_targets
    original = configuration
    before = Marshal.dump(original)
    result = Rho::BotPolicy.external(original, send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES)

    assert_equal "rules", result.fetch(:approval_mode)
    assert_empty result.fetch(:runner_executor_public_ids)
    assert_empty result.fetch(:runner_tool_names)
    assert_equal original.fetch(:mcp_tools), result.fetch(:mcp_tools)
    assert_equal %w[nexus.memory.read nexus.memory.write nexus.tools.search nexus.models.list], result.fetch(:kernel_tools)
    assert_equal %w[send_message spawn], result.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }
    assert_equal [{ "tool" => "memory_read|memory_write|tool_search|models_list", "verdict" => "allow" },
                  { "tool" => "send_message", "path" => "agent", "match" => TARGET.public_id, "verdict" => "allow" },
                  { "tool" => "send_message", "path" => "link_public_id", "match" => "*", "verdict" => "allow" },
                  { "tool" => "spawn", "path" => "declaration", "match" => "worker", "verdict" => "allow" },
                  { "tool" => "spawn", "path" => "declaration", "match" => "reviewer", "verdict" => "allow" }],
      result.fetch(:approval_rules)
    assert_equal "subtree", result.fetch(:conversation_reach)
    assert_equal({ "bindings" => [
      { "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read_write" },
      { "name" => "speaker", "source" => { "scope" => "speaker" }, "access" => "read_write" },
      { "name" => "workspace", "source" => { "scope" => "workspace" }, "access" => "read" },
    ] }, result.fetch(:memory_context_limit))
    refute result.fetch(:prompt_template).fetch("blocks").any? { |block| block["slot"] == "persona" }
    assert_equal "assembly", result.fetch(:prompt_mechanism)
    spawn = result.fetch(:tool_definitions).last
    assert_includes spawn.dig("params", "declaration", "description"), "- worker: Execute the supplied task."
    assert_includes spawn.dig("params", "declaration", "description"), "- reviewer: Review a completed change."
    refute_includes spawn.to_json, TARGET.public_id
    assert_includes spawn.fetch("omit"), "agent"
    assert_equal before, Marshal.dump(original), "the projection never changes the authored configuration"
  end

  def test_external_mcp_keeps_bypass_ask_or_authored_rules_without_widening_bot_destinations
    names = %w[private_read mcp__private__read]
    %w[bypass ask rules].each do |mode|
      authored = [{ "tool" => "*", "verdict" => "allow", "path" => "project", "match" => "selected" },
        { "tool" => "private_read", "verdict" => "deny", "path" => "path", "match" => "/protected/*" },
        { "tool" => "mcp__*", "verdict" => "ask" }]
      result = Rho::BotPolicy.external(configuration.merge(approval_mode: mode, approval_rules: authored),
        send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES, mcp_names: names)
      assert_includes result.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }, "mcp__private__read"
      assert_includes result.fetch(:approval_rules), authored[1]
      assert_includes result.fetch(:approval_rules), authored[2]
      expected = mode == "rules" ? authored.first.merge("tool" => names.join("|")) : { "tool" => names.join("|"), "verdict" => mode == "ask" ? "ask" : "allow" }
      assert_includes result.fetch(:approval_rules), expected
      refute result.fetch(:approval_rules).any? { |rule| rule["tool"] == "*" && rule["verdict"] == "allow" }
    end
  end

  def test_rules_mode_narrows_served_mcp_allows_to_selected_captured_routes
    first = { "type" => "function", "function" => { "name" => "first_mcp" },
      "route" => { "kind" => "runner", "runner_executor_public_id" => "first", "tool_name" => "mcp__files__read" } }
    second = first.merge("function" => { "name" => "second_mcp" },
      "route" => first.fetch("route").merge("runner_executor_public_id" => "second"))
    allow = { "tool" => "mcp__files__read", "path" => "project", "match" => "selected", "verdict" => "allow", "origin" => "author" }
    restrictions = [
      allow.merge("match" => "protected", "verdict" => "deny"),
      allow.merge("match" => "shared", "verdict" => "ask"),
    ]
    original = configuration.merge(tool_definitions: [first, second], approval_mode: "rules", approval_rules: restrictions + [allow])
    result = Rho::BotPolicy.external(original, send_targets: [], spawn_roles: [], wire_names: WIRES, mcp_names: ["first_mcp"])

    assert_equal restrictions, result.fetch(:approval_rules).first(2)
    assert_includes result.fetch(:approval_rules), allow.merge("tool" => "first_mcp")
    refute_includes result.fetch(:approval_rules), allow
    refute result.fetch(:approval_rules).any? { |rule| rule["tool"].include?("second_mcp") }
    assert_includes result.fetch(:tool_definitions), first
    refute_includes result.fetch(:tool_definitions), second
  end

  def test_existing_alias_parameter_maps_and_custom_prompt_blocks_survive_without_a_persona_slot
    original = configuration.merge(prompt_template: {
      "variables" => { "tone" => "brief" },
      "blocks" => [{ "type" => "slot", "slot" => "persona" }, { "type" => "inline", "role" => "system", "text" => "{{tone}}" }],
    })
    before = Marshal.dump(original)
    result = Rho::BotPolicy.external(original, send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES)

    send_alias = result.fetch(:tool_definitions).first
    assert_equal({ "maps_to" => "to" }, send_alias.dig("params", "target"))
    assert_equal "agent", send_alias.dig("params", "agent", "maps_to")
    assert_includes send_alias.dig("params", "agent", "description"), TARGET.public_id
    assert_includes send_alias.dig("params", "agent", "description"), "For direct addressing"
    assert_includes send_alias.dig("params", "agent", "description"), "@helper"
    assert_empty send_alias.fetch("omit")
    assert_equal "Send a message.", send_alias.fetch("description")
    assert_equal({ "variables" => { "tone" => "brief" },
                   "blocks" => [{ "type" => "inline", "role" => "system", "text" => "{{tone}}" }] }, result.fetch(:prompt_template))
    assert_equal before, Marshal.dump(original)
    assert_equal result, Rho::BotPolicy.external(result, send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES)
  end

  def test_spawn_preserves_the_authored_role_parameter_name_and_approval_uses_canonical_input
    spawn = { "type" => "function", "function" => { "name" => "Task" }, "canonical" => "nexus.conversation.spawn",
      "params" => { "agent_type" => { "maps_to" => "declaration" }, "prompt" => { "maps_to" => "message" } },
      "omit" => ["agent", "declaration", "wait"], "description" => "Delegate a task." }
    original = configuration.merge(kernel_tools: [], tool_definitions: [spawn])
    result = Rho::BotPolicy.external(original, send_targets: [TARGET], spawn_roles: ROLES,
      wire_names: WIRES.merge("nexus.conversation.spawn" => "Task"))

    entry = result.fetch(:tool_definitions).first
    assert_equal "declaration", entry.dig("params", "agent_type", "maps_to")
    assert_includes entry.dig("params", "agent_type", "description"), "worker"
    refute entry.fetch("params").key?("declaration")
    assert_equal({ "maps_to" => "message" }, entry.dig("params", "prompt"))
    assert_equal %w[agent wait], entry.fetch("omit")
    assert_equal "Delegate a task.", entry.fetch("description")
    assert_equal ROLES.map { |role| { "tool" => "Task", "path" => "declaration", "match" => role.fetch("name"), "verdict" => "allow" } },
      result.fetch(:approval_rules)
  end

  def test_empty_directories_allow_only_granted_links_and_undeclared_tools_grant_nothing
    result = Rho::BotPolicy.external(configuration, send_targets: [], spawn_roles: [], wire_names: WIRES)
    assert_equal [{ "tool" => "memory_read|memory_write|tool_search|models_list", "verdict" => "allow" },
                  { "tool" => "send_message", "path" => "link_public_id", "match" => "*", "verdict" => "allow" }], result.fetch(:approval_rules)

    empty = configuration.merge(kernel_tools: [], tool_definitions: [])
    result = Rho::BotPolicy.external(empty, send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES)
    assert_empty result.fetch(:approval_rules)
    assert_empty result.fetch(:tool_definitions)
  end

  def test_authored_deny_and_ask_survive_without_private_allow_grants
    restrictions = [
      { "tool" => "send_message", "path" => "agent", "match" => TARGET.public_id, "verdict" => "deny" },
      { "tool" => "spawn", "path" => "declaration", "match" => "reviewer", "verdict" => "ask" },
    ]
    original = configuration.merge(approval_rules: restrictions + [{ "tool" => "*", "verdict" => "allow" }])
    result = Rho::BotPolicy.external(original, send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES)

    assert_equal restrictions, result.fetch(:approval_rules).first(2)
    refute_includes result.fetch(:approval_rules), { "tool" => "*", "verdict" => "allow" }
    assert_equal result, Rho::BotPolicy.external(result, send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES)
  end

  def test_external_memory_ceiling_preserves_disabled_and_read_only_authored_roots
    [[], [{ "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read" }]].each do |bindings|
      authored = { "bindings" => bindings }
      result = Rho::BotPolicy.external(configuration.merge(memory_context_limit: authored),
        send_targets: [TARGET], spawn_roles: ROLES, wire_names: WIRES)

      assert_equal authored, result.fetch(:memory_context_limit)
    end
  end
end
