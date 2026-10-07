require "test_helper"

# Named Agents narrow kernel and custom callables separately from Runner
# served names. Candidate order and the parent's policy remain intact.
class RunDeclarationDerivedTest < Minitest::Test
  RunDeclaration = Rho::RunDeclaration

  Log = Struct.new(:lines) do
    def warn(event, **fields) = lines << [event, fields]
    def info(event, **fields) = lines << [event, fields]
  end

  KERNEL = %w[nexus.conversation.spawn nexus.graph.delegate_task].freeze
  KERNEL_NAMES = { "nexus.conversation.spawn" => "spawn", "nexus.graph.delegate_task" => "delegate_task" }.freeze
  ALIASES = [{ "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.graph.delegate_task" }].freeze

  def registry = @registry ||= Rho::Extensions.load(host: RhoTest.host).registry

  def parent(compaction: { "mode" => "kernel" }, fallback_model: "openai_api/parent-fallback")
    RunDeclaration.declaration(registry: registry, runner_executor_public_ids: %w[remote-runner own-runner],
      kernel_tools: KERNEL, kernel_aliases: ALIASES, compaction: compaction,
      roots: ["/opt/rho"], default_model: "openrouter/parent/model", fallback_model: fallback_model)
  end

  def agent_names = RunDeclaration.tool_entries(RunDeclaration.announcement(registry: registry.serving(:agent)))
    .map { |entry| entry.dig("function", "name") }

  def definition(tools: nil, model: nil, fallback_model: nil, body: "You review.", name: "reviewer")
    Rho::Agents::Definition.new(name: name, description: "Reviews a diff.", tools: tools, model: model,
      fallback_model: fallback_model, body: body, path: "/work/.agents/agents/#{name}.md", ignored_keys: [])
  end

  def derive(definition, parent_declaration = parent)
    @log = Log.new([])
    RunDeclaration.derived_declaration(parent_declaration, definition, agent_names: agent_names, kernel_tool_names: KERNEL_NAMES,
      runner_names: RunDeclaration.runner_model_tool_names(RunDeclaration.announcement(registry: registry.serving(:runner))), log: @log)
  end

  def names(declaration) = declaration.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }

  def test_absent_tools_keeps_sources_and_aliases_without_agent_only_callables
    declaration = derive(definition)

    assert_includes agent_names, "todo_write", "the fixture: rho's agent address announces a name"
    assert_equal names(parent) - agent_names, names(declaration)
    assert_equal KERNEL, declaration.fetch(:kernel_tools)
    assert_nil declaration.fetch(:runner_tool_names)
    assert_equal %w[remote-runner own-runner], declaration.fetch(:runner_executor_public_ids)
    assert_includes names(declaration), "Agent"
    refute_includes names(declaration), "todo_write"
    assert_empty @log.lines
  end

  def test_mixed_names_separate_kernel_selection_from_runner_served_names
    declaration = derive(definition(tools: %w[spawn read grep]))

    assert_equal [], names(declaration)
    assert_equal ["nexus.conversation.spawn"], declaration.fetch(:kernel_tools)
    assert_equal %w[read grep], declaration.fetch(:runner_tool_names)
    assert_empty @log.lines
  end

  def test_canonical_kernel_and_compact_alias_names_do_not_become_runner_names
    declaration = derive(definition(tools: %w[nexus.conversation.spawn Agent read]))
    assert_equal ["nexus.conversation.spawn"], declaration.fetch(:kernel_tools)
    assert_equal ALIASES, declaration.fetch(:tool_definitions)
    assert_equal ["read"], declaration.fetch(:runner_tool_names)
    assert_empty @log.lines
  end

  def test_canonical_selection_keeps_current_aliases_without_a_plain_kernel_export
    declaration = derive(definition(tools: %w[nexus.graph.delegate_task read]), parent.merge(kernel_tools: []))

    assert_empty declaration.fetch(:kernel_tools)
    assert_equal ALIASES, declaration.fetch(:tool_definitions)
    assert_equal ["read"], declaration.fetch(:runner_tool_names)
    assert_empty @log.lines
  end

  def test_a_kernel_name_not_enabled_plainly_does_not_become_a_runner_request
    declaration = derive(definition(tools: ["delegate_task"]), parent.merge(kernel_tools: []))
    assert_empty declaration.fetch(:tool_definitions)
    assert_empty declaration.fetch(:runner_tool_names)
    assert_equal [["agents.skipped_tool", { path: "/work/.agents/agents/reviewer.md", tool: "delegate_task" }]], @log.lines
  end

  def test_a_custom_and_runner_name_can_both_remain_selected
    read = RunDeclaration.tool_entries([NexusDoubles.served_tool("read")]).first
    source = parent.merge(tool_definitions: [read])
    declaration = derive(definition(tools: ["read"]), source)
    assert_equal [read], declaration.fetch(:tool_definitions)
    assert_equal ["read"], declaration.fetch(:runner_tool_names)
    assert_empty @log.lines
  end

  def test_an_agent_only_copy_is_removed_without_losing_a_runner_with_the_same_name
    source = parent.merge(tool_definitions: RunDeclaration.tool_entries([NexusDoubles.served_tool("code")]))
    declaration = RunDeclaration.derived_declaration(source, definition(tools: ["code"]),
      agent_names: ["code"], runner_names: ["code"], kernel_tool_names: KERNEL_NAMES)
    assert_empty declaration.fetch(:tool_definitions)
    assert_equal ["code"], declaration.fetch(:runner_tool_names)
  end

  def test_a_name_from_an_unloaded_candidate_is_preserved_as_runner_intent
    declaration = derive(definition(tools: ["remote_tool"]))
    assert_equal ["remote_tool"], declaration.fetch(:runner_tool_names)
    assert_empty @log.lines
  end

  def test_a_parent_runner_allowlist_cannot_be_widened
    source = parent.merge(runner_tool_names: ["read"])
    assert_equal ["read"], derive(definition, source).fetch(:runner_tool_names)
    assert_equal ["read"], derive(definition(tools: %w[read write]), source).fetch(:runner_tool_names)
    assert_equal [["agents.skipped_tool", { path: "/work/.agents/agents/reviewer.md", tool: "write" }]], @log.lines
  end

  # `[]` is none: a reply from context alone, the mode still written.
  def test_empty_tools_is_none
    declaration = derive(definition(tools: []))

    assert_equal [], declaration.fetch(:tool_definitions)
    assert_equal [], declaration.fetch(:kernel_tools)
    assert_equal [], declaration.fetch(:runner_tool_names)
    assert_equal "bypass", declaration.fetch(:approval_mode)
  end

  # A name the universe does not hold is dropped and logged; an
  # agent-served name is never in the universe, even when listed.
  def test_an_unknown_or_agent_served_name_is_dropped_and_logged
    declaration = derive(definition(tools: %w[read nope todo_write]), parent.merge(runner_tool_names: ["read"]))

    assert_empty names(declaration)
    assert_equal ["read"], declaration.fetch(:runner_tool_names)
    assert_equal [["agents.skipped_tool", { path: "/work/.agents/agents/reviewer.md", tool: "nope" }],
                  ["agents.skipped_tool", { path: "/work/.agents/agents/reviewer.md", tool: "todo_write" }]],
      @log.lines
  end

  def test_without_candidates_unknown_names_are_not_promised_as_runner_tools
    declaration = derive(definition(tools: ["read"]), parent.merge(runner_executor_public_ids: []))
    assert_empty declaration.fetch(:runner_tool_names)
    assert_equal [["agents.skipped_tool", { path: "/work/.agents/agents/reviewer.md", tool: "read" }]], @log.lines
  end

  # A named agent keeps its own prompt policy and the parent's approval posture.
  def test_the_parents_mode_and_rules_ride_whole_without_its_prompt_template
    declaration = derive(definition(tools: %w[read]))

    assert_equal parent.fetch(:approval_mode), declaration.fetch(:approval_mode)
    assert_equal parent.fetch(:approval_rules), declaration.fetch(:approval_rules)
    assert_equal "default", declaration.fetch(:prompt_mechanism)
    assert_nil declaration.fetch(:prompt_template)
    assert_equal %i[tool_definitions kernel_tools runner_executor_public_ids runner_tool_names approval_mode approval_rules prompt_mechanism prompt_template
                    compaction_policy default_model fallback_model], declaration.keys
  end

  # `delegate` lowers to the kernel's: the delegate summarizer is announced
  # on the parent's agent address the row does not have.
  def test_a_delegate_compaction_policy_lowers_to_the_kernels
    kernel = derive(definition, parent(compaction: { "mode" => "kernel", "budget_tokens" => 4096 }))
    assert_equal({ "mode" => "kernel", "budget_tokens" => 4096 }, kernel.fetch(:compaction_policy))

    delegate = derive(definition, parent(compaction: { "mode" => "delegate", "tool_name" => "summarize_history", "budget_tokens" => 4096 }))
    assert_equal({ "mode" => "kernel", "budget_tokens" => 4096 }, delegate.fetch(:compaction_policy))

    off = derive(definition, parent(compaction: { "mode" => "off" }))
    assert_equal({ "mode" => "off" }, off.fetch(:compaction_policy))
  end

  # The file's `model` is the row's `default_model`; absent, nil — never
  # the parent's preset (an unnamed model means the initiator's).
  def test_the_files_model_is_the_default_model_and_absent_is_nil
    assert_equal "dev/text", derive(definition(model: "dev/text")).fetch(:default_model)
    assert_nil derive(definition).fetch(:default_model)
    assert_equal "openrouter/parent/model", parent.fetch(:default_model), "the parent's preset is the parent's alone"
  end

  # THE FALLBACK PAIRS WITH THE MODEL IT BACKS. A definition that names no
  # `model:` runs on the initiator's — rho's own line — and inherits the
  # parent's `fallback_model`; one that names its own model declares its
  # own `fallback_model:` or none, because the parent's fallback was chosen
  # for the parent's model. A file's own `fallback_model:` is its word
  # either way.
  def test_the_fallback_is_inherited_only_by_a_definition_that_names_no_model
    assert_equal "openai_api/parent-fallback", derive(definition).fetch(:fallback_model),
      "no model: the initiator's line, the parent's fallback"
    assert_nil derive(definition(model: "dev/text")).fetch(:fallback_model),
      "its own model and no fallback of its own: none"
    assert_equal "dev/fallback",
      derive(definition(model: "dev/text", fallback_model: "dev/fallback"))
        .fetch(:fallback_model), "its own model, its own fallback"
    assert_equal "openrouter/own-fallback", derive(definition(fallback_model: "openrouter/own-fallback")).fetch(:fallback_model),
      "a file's own fallback beats the parent's"
    assert_nil derive(definition, parent(fallback_model: nil)).fetch(:fallback_model), "nothing to inherit"
  end

  # ---- the roster ----

  def test_the_roster_describes_agents_without_copying_their_tool_authority
    rows = [
      { handle: "reviewer", description: "Reviews a diff for defects and reports only what matters; use it after a change lands, before a commit",
        tool_names: %w[read grep bash glob] },
      { handle: "docs", description: "Writes the docs for a change and answers with the paths it wrote", tool_names: [] },
    ]

    assert_equal <<~TEXT.strip, RunDeclaration.roster(rows)
      Agents here you can hand work to by @handle (the `agent` argument of a spawn or a send); each starts with an empty context, answers with its own tools, and reports back to you:
      - @reviewer: Reviews a diff for defects and reports only what matters; use it after a change lands, before a commit
      - @docs: Writes the docs for a change and answers with the paths it wrote
    TEXT
  end

  def test_the_slot_is_stable_and_the_kind_is_declared_after_history
    assert_nil RunDeclaration.roster([])
    assert_equal "environment\n\n- @x: y", RunDeclaration.execution_lead("environment", roster: "- @x: y")
    refute_includes RunDeclaration::GUIDELINE, "{{conversation_kind}}"

    declaration = parent
    assert_equal "assembly", declaration.fetch(:prompt_mechanism)
    blocks = declaration.fetch(:prompt_template).fetch("blocks")
    assert_equal %w[slot slot slot memory history skills lead tail inline input], blocks.map { |block| block.fetch("type") }
    assert_equal %w[system_prompt character persona], blocks.filter_map { |block| block["slot"] }
    assert_equal({ "type" => "inline", "role" => "user", "text" => "Conversation kind: {{conversation_kind}}." },
      blocks.fetch(-2), "the current kind merges into the input after inherited history")
  end

  def test_a_named_agents_custom_template_is_preserved_whole
    template = { "blocks" => [{ "type" => "history" }, { "type" => "input" }] }
    declaration = derive(definition.with(prompt_template: template))

    assert_equal "assembly", declaration.fetch(:prompt_mechanism)
    assert_equal template, declaration.fetch(:prompt_template)
  end

  # The heading names the `agent` ARGUMENT, never a kernel tool a preset
  # re-spells (the guideline's own discipline).
  def test_the_roster_heading_names_no_aliasable_kernel_word
    heading = RunDeclaration::ROSTER_HEADING
    %w[`task` `Agent` `spawn` `send`].each { |word| refute_includes heading, word }
    assert_includes heading, "`agent`"
  end
end
