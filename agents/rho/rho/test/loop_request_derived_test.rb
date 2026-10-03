require "test_helper"

# THE DERIVED DECLARATION and THE
# ROSTER: a named definition's configuration is rho's ONE
# declaration NARROWED — the universe is the parent's union minus every
# name announced on rho's AGENT address (a named row has no address, so an
# agent-served call would fail `tool_not_served` at start), `tools:` an
# exact allowlist over it (kernel names included), the parent's mode and
# rules whole, the compaction policy with `delegate` lowered to the
# kernel's, the file's `model` as `default_model`. The
# roster is one neutral heading and one line per agent, the stored names
# sorted; no model.
class LoopRequestDerivedTest < Minitest::Test
  LoopRequest = Rho::LoopRequest

  Log = Struct.new(:lines) do
    def warn(event, **fields) = lines << [event, fields]
    def info(event, **fields) = lines << [event, fields]
  end

  KERNEL = [
    { "type" => "function", "function" => { "name" => "spawn", "description" => "Spawn.", "parameters" => {} } },
    { "type" => "function", "function" => { "name" => "task", "description" => "Task.", "parameters" => {} } },
  ].freeze

  def registry = @registry ||= Rho::Extensions.load(host: RhoTest.host).registry

  def parent(compaction: { "mode" => "kernel" }, fallback_model: "openai_api/parent-fallback")
    LoopRequest.declaration(registry: registry, kernel_tools: KERNEL, compaction: compaction,
      roots: ["/opt/rho"], default_model: "openrouter/parent/model", fallback_model: fallback_model)
  end

  def agent_names = LoopRequest.tool_entries(LoopRequest.announcement(registry: registry.serving(:agent)))
    .map { |entry| entry.dig("function", "name") }

  def definition(tools: nil, model: nil, fallback_model: nil, body: "You review.", name: "reviewer")
    Rho::Agents::Definition.new(name: name, description: "Reviews a diff.", tools: tools, model: model,
      fallback_model: fallback_model, body: body, path: "/work/.agents/agents/#{name}.md", ignored_keys: [])
  end

  def derive(definition, parent_declaration = parent)
    @log = Log.new([])
    LoopRequest.derived_declaration(parent_declaration, definition, agent_names: agent_names, log: @log)
  end

  def names(declaration) = declaration.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }

  # The universe: the runner's entries and the kernel's, never the agent
  # address's; absent `tools:` is the whole of it.
  def test_absent_tools_is_the_whole_universe_minus_the_agent_served_names
    declaration = derive(definition)

    assert_includes agent_names, "todo_write", "the fixture: rho's agent address announces a name"
    assert_equal names(parent) - agent_names, names(declaration)
    assert_includes names(declaration), "spawn"
    assert_includes names(declaration), "bash"
    refute_includes names(declaration), "todo_write"
    assert_empty @log.lines
  end

  # An exact allowlist over the universe, kernel names included; the
  # entries are the parent's bytes, in the parent's order.
  def test_tools_is_an_exact_allowlist_over_the_universe
    declaration = derive(definition(tools: %w[spawn read grep]))

    assert_equal %w[grep read spawn], names(declaration)
    assert_equal parent.fetch(:tool_definitions).select { |entry| %w[grep read spawn].include?(entry.dig("function", "name")) },
      declaration.fetch(:tool_definitions), "the parent's entries, byte for byte"
    assert_empty @log.lines
  end

  # `[]` is none: a reply from context alone, the mode still written.
  def test_empty_tools_is_none
    declaration = derive(definition(tools: []))

    assert_equal [], declaration.fetch(:tool_definitions)
    assert_equal "bypass", declaration.fetch(:approval_mode)
  end

  # A name the universe does not hold is dropped and logged; an
  # agent-served name is never in the universe, even when listed.
  def test_an_unknown_or_agent_served_name_is_dropped_and_logged
    declaration = derive(definition(tools: %w[read nope todo_write]))

    assert_equal %w[read], names(declaration)
    assert_equal [["agents.skipped_tool", { path: "/work/.agents/agents/reviewer.md", tool: "nope" }],
                  ["agents.skipped_tool", { path: "/work/.agents/agents/reviewer.md", tool: "todo_write" }]],
      @log.lines
  end

  # A named agent keeps its own prompt policy and the parent's approval posture.
  def test_the_parents_mode_and_rules_ride_whole_without_its_prompt_template
    declaration = derive(definition(tools: %w[read]))

    assert_equal parent.fetch(:approval_mode), declaration.fetch(:approval_mode)
    assert_equal parent.fetch(:approval_rules), declaration.fetch(:approval_rules)
    assert_equal "default", declaration.fetch(:prompt_mechanism)
    assert_nil declaration.fetch(:prompt_template)
    assert_equal %i[tool_definitions approval_mode approval_rules prompt_mechanism prompt_template
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

  def test_the_roster_is_one_heading_and_one_line_per_agent_the_names_sorted
    rows = [
      { handle: "reviewer", description: "Reviews a diff for defects and reports only what matters; use it after a change lands, before a commit",
        tool_names: %w[read grep bash glob] },
      { handle: "docs", description: "Writes the docs for a change and answers with the paths it wrote", tool_names: [] },
    ]

    assert_equal <<~TEXT.strip, LoopRequest.roster(rows)
      Agents here you can hand work to by @handle (the `agent` argument of a spawn or a send); each starts with an empty context, answers with its own tools, and reports back to you:
      - @reviewer: Reviews a diff for defects and reports only what matters; use it after a change lands, before a commit (tools: bash, glob, grep, read)
      - @docs: Writes the docs for a change and answers with the paths it wrote (tools: none)
    TEXT
  end

  def test_the_slot_is_stable_and_the_kind_is_declared_after_history
    assert_nil LoopRequest.roster([])
    assert_equal LoopRequest::GUIDELINE, LoopRequest.guideline_slot(nil)
    assert_equal "#{LoopRequest::GUIDELINE}\n\n- @x: y (tools: none)",
      LoopRequest.guideline_slot("- @x: y (tools: none)")
    refute_includes LoopRequest.guideline_slot(nil), "{{conversation_kind}}"

    declaration = parent
    assert_equal "assembly", declaration.fetch(:prompt_mechanism)
    blocks = declaration.fetch(:prompt_template).fetch("blocks")
    assert_equal %w[slot slot slot memory skills history lead tail inline input], blocks.map { |block| block.fetch("type") }
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
    heading = LoopRequest::ROSTER_HEADING
    %w[`task` `Agent` `spawn` `send`].each { |word| refute_includes heading, word }
    assert_includes heading, "`agent`"
  end
end
