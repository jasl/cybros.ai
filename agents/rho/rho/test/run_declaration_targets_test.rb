require_relative "run_declaration_test"

class RunDeclarationTest
  def test_same_name_on_two_runners_declares_candidates_without_importing_either_schema
    first = NexusDoubles.served_tool("read", description: "reads an image")
      .merge("input_schema" => { "type" => "object", "properties" => { "image" => { "type" => "string" } }, "required" => ["image"] })
    second = NexusDoubles.served_tool("read", description: "reads a file")
      .merge("input_schema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } }, "required" => ["path"] })
    docs = [RunnerDocument.new(public_id: "runner-a", served_tools: [first]),
            RunnerDocument.new(public_id: "runner-b", served_tools: [second])]
    declared = Rho::RunDeclaration.declaration(registry: registry, remote: docs,
      runner_executor_public_ids: %w[runner-b runner-a])
    assert_equal %w[runner-b runner-a], declared.fetch(:runner_executor_public_ids)
    assert_nil declared.fetch(:runner_tool_names)
    assert_equal Rho::RunDeclaration.declaration(registry: registry).fetch(:tool_definitions), declared.fetch(:tool_definitions)
    refute declared.fetch(:tool_definitions).any? { |entry| entry.key?("route") }
    assert declared.fetch(:approval_rules).any? { |rule|
      rule.except("tool") == { "verdict" => "allow" } &&
        rule.fetch("tool").split("|").any? { |pattern| glob(pattern).match?("read") }
    }, "approval remains a served-name policy independent of imported Runner schemas"
  end

  def test_kernel_and_runner_skill_sources_are_requested_without_local_aliases
    declared = Rho::RunDeclaration.declaration(registry: registry, kernel_tools: ["nexus.skill.load"],
      runner_executor_public_ids: ["own-runner"], runner_tool_names: ["skill"])
    assert_equal ["nexus.skill.load"], declared.fetch(:kernel_tools)
    assert_equal ["skill"], declared.fetch(:runner_tool_names)
    refute_includes declared.fetch(:tool_definitions).map { |entry| name_of(entry) }, "skill"
  end

  def test_code_keeps_one_agent_facade_and_requests_runner_sources_separately
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [], gems: ["rho/codemode"])
    served = Rho::RunDeclaration.announcement(registry: loaded.registry.serving(:runner))
    remote = RunnerDocument.new(public_id: "remote-runner", served_tools: served)
    declared = Rho::RunDeclaration.declaration(registry: loaded.registry, remote: [remote],
      runner_executor_public_ids: %w[own-runner remote-runner])

    eager = declared.fetch(:tool_definitions).reject { |entry| entry["defer_loading"] }
    assert_equal ["code"], eager.map { |entry| name_of(entry) }
    assert_equal %w[own-runner remote-runner], declared.fetch(:runner_executor_public_ids)
    assert_nil declared.fetch(:runner_tool_names)
    assert_equal 1, declared.fetch(:tool_definitions).count { |entry| Rho::CodeMode.code?(entry) }
    assert_empty Rho::CodeMode.tools(declared.fetch(:tool_definitions), false)
  end

  def test_runner_policy_names_exclude_operator_capabilities_without_copying_schemas
    served = [NexusDoubles.served_tool("read"), NexusDoubles.served_tool("files_bytes"),
              NexusDoubles.served_tool("operator_only").except("description", "input_schema")]
    assert_equal ["read"], Rho::RunDeclaration.runner_model_tool_names(served)
    declared = Rho::RunDeclaration.declaration(registry: registry, runner_tool_names: %w[read files_bytes code])
    assert_equal %w[read code], declared.fetch(:runner_tool_names)
    assert_equal [], Rho::RunDeclaration.declaration(registry: registry, runner_tool_names: []).fetch(:runner_tool_names)
  end

  def test_a_remote_served_policy_requires_the_selected_runner_context
    error = assert_raises(ArgumentError) do
      Rho::RunDeclaration.steps(prompt: "work", model: "dev/test", registry: registry,
        served: [NexusDoubles.served_tool("read")], runner_executor_public_ids: ["candidate"])
    end
    assert_equal "a served Runner list requires runner_executor_public_id", error.message
  end

  def test_code_mode_off_narrows_an_explicit_remote_tool_allowlist_by_served_name
    served = [NexusDoubles.served_tool("read"), NexusDoubles.served_tool("code"), NexusDoubles.served_tool("files_bytes")]
    step, = Rho::RunDeclaration.steps(prompt: "work", model: "dev/test", registry: registry, served: served,
      runner_executor_public_id: "remote", runner_executor_public_ids: ["remote"], runner_tool_names: %w[read code files_bytes], code_mode: false)
    assert_equal ["read"], step.runner_tool_names
    assert_equal ["remote"], step.runner_executor_public_ids
  end

  def test_mcp_and_editor_provider_schemas_are_deferred_without_losing_their_exact_schema
    mcp = NexusDoubles.served_tool("mcp__files__read")
    assert_equal true, Rho::RunDeclaration.tool_entries([mcp]).first.fetch("defer_loading")

    editor = NexusDoubles.served_tool("editor_diagnostics", description: "Current editor diagnostics")
    declaration = Rho::RunDeclaration.declaration(registry: registry, extras: [editor])
    entry = declaration.fetch(:tool_definitions).find { |tool| name_of(tool) == "editor_diagnostics" }
    assert_equal true, entry.fetch("defer_loading")
    assert_equal editor.fetch("input_schema"), entry.dig("function", "parameters")
    assert_equal editor.fetch("description"), entry.dig("function", "description")
  end
end
