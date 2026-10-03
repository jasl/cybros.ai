require "minitest/autorun"
require "active_support/all"
require "yaml"
require "cybros_agent"
require_relative "../../nexus/lib/nexus/tool_registry"
require_relative "../../nexus/lib/nexus/tool_announcements"
require_relative "../../nexus/lib/nexus/tool_declarations"
require_relative "../../nexus/lib/nexus/tool_declarations/render"

# THE KERNEL'S BYTES NAME NO RUNNER TOOL: the `task` description used to say "call `read`/`grep`
# yourself" and "do not use `start_process`" — ONE runner's names on every model's cached prefix.
# Those facts are rho's to state, in rho's `system_prompt` slot (`LoopRequest::GUIDELINE`, pinned to
# rho's own registry in rho's suite); the kernel's texts quote none of them. The coupling that
# remains lives where both trees load — here, never in nexus's own suite: no backticked word in a
# kernel description is a name rho declares, and the SDK's model-adaptations pack names the kernel's
# tools by canonical and plain name, re-cuts its templates by ANCHOR, and declares alias sets the
# kernel's own door accepts — each pinned here against the registry, never inside the gem, which
# cannot load the kernel.
class KernelToolNamesTest < Minitest::Test
  RHO_RUNNER_LIB = File.expand_path("../../agents/rho/rho-runner/lib", __dir__)
  RHO_LIB = File.expand_path("../../agents/rho/rho/lib", __dir__)
  PACK = CybrosAgent::ModelAdaptations.load
  CANDIDATES = Dir[File.expand_path("../evals/candidates/*.yml", __dir__)].sort

  # rho's registry, through the DAEMON's handle (r-modes M1): the seven coding tools the runner
  # carries alone, the checkpoint store's two hidden names (a module on host state — the host hands
  # the store's member, here a callable answering a throwaway store, the daemon's own shape), the
  # daemon's processes extension, its delegate summarizer and its todo tracker — the agent's own
  # tools, which a standalone runner's handle refuses by design — the same tool sources rho's boot
  # declaration and its two boot announcements assemble.
  def rho_registry
    $LOAD_PATH.unshift(RHO_RUNNER_LIB) unless $LOAD_PATH.include?(RHO_RUNNER_LIB)
    $LOAD_PATH.unshift(RHO_LIB) unless $LOAD_PATH.include?(RHO_LIB)
    require "rho"
    require "tmpdir"
    root = Dir.mktmpdir("rho-kernel-tool-names-world")
    Minitest.after_run { FileUtils.remove_entry(root) if File.directory?(root) }
    store = Rho::Runner::Checkpoints::Store.open(dir: File.join(root, "checkpoints"), root: root)
    host = Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(Dir.tmpdir, "rho-kernel-tool-names")),
      log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil,
      checkpoints: -> { store }
    )
    Rho::Extensions.load(
      host: host,
      extensions: [Rho::Runner::Extensions::Coding, Rho::Runner::Extensions::Checkpoints,
                   Rho::Extensions::Processes, Rho::Extensions::Compaction, Rho::Extensions::Todo]
    ).registry
  end

  def rho_tool_names
    rho_registry.declarations.map { |declaration| declaration.fetch("name") }
  end

  def test_no_kernel_description_quotes_a_tool_rho_declares
    declared = rho_tool_names
    refute_empty declared
    assert_includes declared, "read"
    assert_includes declared, "start_process"

    Nexus::ToolRegistry::LIVE.each_value do |tool|
      quoted = tool.description.scan(/`([a-z_]+)`/).flatten.uniq
      assert_empty quoted & declared,
        "#{tool.name}: the kernel's bytes quote a runner's tool — rho describes its own tools in its guideline"
    end
  end

  def kernel_definitions = Nexus::ToolRegistry::LIVE.values.map(&:function_definition)

  def kernel_templates = Nexus::ToolRegistry::LIVE.values.to_h { |tool| [tool.canonical, tool.template] }

  # THE TABLES NAME THE KERNEL'S TOOLS: every alias canonical is a live kernel tool, every `plain`
  # entry is that tool's wire name (the harness pins each, the gem knows no registry), and a preset
  # re-spells nothing the tables cannot name plainly.
  def test_the_packs_tables_name_live_kernel_tools_by_their_wire_names
    presets = PACK.presets
    presets.plain.each do |canonical, name|
      assert Nexus::ToolRegistry::LIVE.key?(canonical), "#{canonical}: not a live kernel tool"
      assert_equal Nexus::ToolRegistry.entry(canonical).name, name, "#{canonical}: the plain name is the kernel's wire name"
    end
    presets.presets.each_value do |preset|
      preset.supersedes.each { |canonical| assert Nexus::ToolRegistry::LIVE.key?(canonical), "#{preset.word} supersedes #{canonical}: unknown" }
      preset.aliases.each do |spec|
        assert Nexus::ToolRegistry::LIVE.key?(spec.fetch("canonical")), "#{spec.fetch("name")}: not a live kernel tool"
        refute Nexus::ToolRegistry.kernel_name?(spec.fetch("name")), "#{spec.fetch("name")}: a kernel name is never an alias name"
      end
    end
  end

  # THE ANCHOR STANDS ( the pack's recuts in place of the copies): each `recut` of the presets and
  # of the harness's candidate entries names ONE paragraph the kernel's template carries verbatim,
  # so a kernel re-cut that moves it fails here first — and at a home's boot `AnchorMoved` names the
  # entry, never a silent no-op.
  def test_every_recut_anchor_stands_in_the_kernels_template
    templates = kernel_templates
    specs = PACK.presets.presets.values.flat_map(&:aliases) + PACK.rows.flat_map(&:tool_descriptions) + candidate_entries
    recuts = specs.select { |spec| spec.key?("recut") }
    assert_equal %w[Agent spawn_agent], recuts.map { |spec| spec.fetch("name") },
      "the two preset recuts; the candidate files carry no entry (kimi's `agent-without-example` was deleted 2026-09-16)"
    recuts.each do |spec|
      template = templates.fetch(spec.fetch("canonical"))
      anchor = spec.dig("recut", "anchor")
      assert_includes template, anchor, "#{spec.fetch("name")}: the anchor moved; re-cut the entry"
      assert_equal 1, template.scan(anchor).size, "#{spec.fetch("name")}: the anchor must stand once"
      rendered = CybrosAgent::ModelAdaptations::Styles.entry(spec, templates: templates).fetch("description")
      assert_equal template.sub(anchor) { spec.dig("recut", "replacement") }, rendered
      refute_includes rendered, anchor
      assert_includes rendered, "{{#{Nexus::ToolRegistry.entry(spec.fetch("canonical")).name}}}", "a macro the kernel spells at declaration"
    end
  end

  # THE KERNEL IS THE ONE VALIDATOR OF AN ALIAS: the loader keeps no name
  # rule, so every gem row's whole entry set — and each style word alone,
  # the shape the benches build — passes `ToolDeclarations.refusal` here
  # (no `alias_name_reserved`, no `duplicate_tool_name`, no
  # `alias_param_unknown`) and renders to a set the store would hold.
  def test_every_gem_rows_entry_set_passes_the_kernels_declaration_door
    definitions = kernel_definitions
    templates = kernel_templates
    rows = PACK.rows + PACK.presets.words.map { |word| PACK.default.with(id: word, tool_style: [word]) }
    rows.each do |row|
      entries = PACK.apply(definitions, row, templates: templates)
      assert_nil Nexus::ToolDeclarations.refusal(entries), "row #{row.id}: the kernel's door refuses the set"
      rendered = Nexus::ToolDeclarations.render(entries)
      assert_equal entries.size, rendered.size
      assert_equal entries.map { |entry| entry.dig("function", "name") }, Nexus::ToolDeclarations.names(rendered)
    end
    claude = PACK.apply(definitions, PACK.row("claude"), templates: templates)
    assert_equal %w[Agent AskUserQuestion Skill], Nexus::ToolDeclarations.names(claude).last(3)
    refute_includes Nexus::ToolDeclarations.names(claude), "task"
    agent = Nexus::ToolDeclarations.render(claude).find { |entry| entry.dig("function", "name") == "Agent" }
    assert_includes agent.dig("function", "description"), "several `Agent` calls in ONE message", "the macro spelled as the alias"
    assert_equal %w[prompt lifetime wake run_in_background tools], agent.dig("function", "parameters", "properties").keys
    assert_equal true, agent.dig("function", "parameters", "properties", "run_in_background", "default"), "the inverted default"
    # THE ASK ALIAS STAYS THE KERNEL'S FLAT SHAPE (audit refs-parity-6): the
    # alias mechanism maps flat keys only, so `AskUserQuestion` is spelled
    # over `prompt`/`options`/`multi` — never Claude Code's nested
    # `questions[0].{question,options,multiSelect}` (recorded at
    # presets.yml; the paid window benches the cell as-is).
    ask = Nexus::ToolDeclarations.render(claude).find { |entry| entry.dig("function", "name") == "AskUserQuestion" }
    assert_equal %w[prompt options multi], ask.dig("function", "parameters", "properties").keys
    assert_equal "array", ask.dig("function", "parameters", "properties", "options", "type")
    assert_equal ["prompt"], ask.dig("function", "parameters", "required")
  end

  def candidate_entries
    CANDIDATES.flat_map do |path|
      YAML.safe_load(File.read(path, encoding: Encoding::UTF_8)).fetch("candidates")
        .select { |candidate| candidate.fetch("kind") == "tool_descriptions" }.map { |candidate| candidate.fetch("entry") }
    end
  end

  # THE TWO ANNOUNCEMENTS ARE THE DECLARATION'S MACHINE HALF: what rho announces on each ADDRESS of
  # the executor plane — what the kernel addresses work by — is computed from the same registry as
  # what it declares — what the model sees — by projections of one registry, and every entry passes
  # the kernel's own door rules: exactly the effect vocabulary, the declaration facts in the
  # kernel's shape, no kernel name, so neither boot announcement is ever refused
  # `invalid_announcement`, `reserved_namespace` or `reserved_tool_name`. The RUNNER address
  # announces this machine's environment tools, every one a name the model may call; the AGENT
  # address announces EXACTLY ONE: the delegate summarizer, addressed by the profile's compaction
  # policy NAME and never offered to a model. No Coding or Processes name on the agent announcement:
  # an agent-mode rho serves no environment tool of its own. The RUNNER address announces five more
  # names a model is never offered — the person's reads through the relay (`files_bytes`,
  # `process_log`), the kernel's skill load (`skill` — the profile declares the KERNEL's tool of
  # that name, and the runner's announced one is where the kernel delivers a load of a name the
  # runner announced under `documents`), and the checkpoint store's two (`world_restore`, a member's
  # restore through a request loop, and the `checkpoints` read) — hidden by name
  # (`LoopRequest.undeclared`) and announced DESCRIBED TO NOBODY (no description, no schema;
  # `world_restore` its park alone), so no peer can author a declaration from them. The set is
  # EXACT: a sixth unoffered announced name is a drift this pin fails on, and from here on no kernel
  # description may backtick `skill` (the first pin above).
  def test_each_addresss_announcement_is_the_declarations_machine_half
    registry = rho_registry
    runner = Rho::LoopRequest.announcement(registry: registry.serving(:runner))
    agent = Rho::LoopRequest.announcement(registry: registry.serving(:agent))
    # The model's fact: the declaration's `tool_definitions` are the registry's entries as
    # `LoopRequest.tool_entries` offers them — fed the announcement, the one served shape both
    # feeders share.
    declared = Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: registry))
      .map { |entry| entry.dig("function", "name") }

    refute_empty runner
    undescribed = registry.serving(:runner).entries.select(&:undescribed?).map(&:name).sort
    assert_equal %w[checkpoints files_bytes process_log skill world_restore], undescribed
    assert_equal undescribed, (runner.map { |entry| entry.fetch("name") } - declared).sort,
      "every name the runner address announces is one the model may call, except the person's reads, " \
      "the skill load and the store's two"
    runner.select { |entry| undescribed.include?(entry.fetch("name")) }.each do |entry|
      expected = entry.fetch("name") == "world_restore" ? %w[effect_profile name timeout_ms] : %w[effect_profile name]
      assert_equal expected, entry.keys.sort, "#{entry["name"]} is announced described to nobody"
    end
    assert_equal [Rho::Extensions::Compaction::TOOL_NAME, Rho::Extensions::Todo::Write::NAME],
      agent.map { |entry| entry.fetch("name") },
      "the agent address announces the delegate and the todo tracker (capabilities III C1); it announced another"
    assert_equal [Rho::Extensions::Compaction::TOOL_NAME], agent.map { |entry| entry.fetch("name") } - declared,
      "the delegate is the one announced name a model is never offered; `todo_write` is declared"
    assert_includes declared, Rho::Extensions::Todo::Write::NAME
    assert_equal registry.names.sort, (runner + agent).map { |entry| entry.fetch("name") }.sort,
      "the two addresses partition the registry: nothing lost, nothing announced twice"
    refute(runner.any? { |entry| entry.fetch("name") == Rho::Extensions::Compaction::TOOL_NAME })
    refute(agent.any? { |entry| %w[bash read start_process].include?(entry.fetch("name")) },
      "no Coding or Processes name on the agent announcement")
    (runner + agent).each do |entry|
      assert_equal Nexus::ToolRegistry::EFFECT_KEYS, entry.fetch("effect_profile").keys,
        "#{entry.fetch("name")} announces a profile outside the kernel's vocabulary"
      next if undescribed.include?(entry.fetch("name"))

      assert entry.key?("description") && entry.fetch("input_schema")["type"] == "object",
        "#{entry.fetch("name")} announces without the declaration's facts"
    end
    [runner, agent].each do |announced|
      assert_nil Nexus::ToolAnnouncements.refusal(announced), "the kernel's door would refuse rho's own announcement"
    end
    assert_equal Nexus::ToolAnnouncements::ENTRY_KEYS.sort,
      (runner + agent).flat_map(&:keys).uniq.sort, "rho announces every key the door keeps, and no other"
  end
end
