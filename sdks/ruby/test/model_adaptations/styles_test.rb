require "test_helper"

# THE UNIVERSE A ROW DECLARES (the `apply` half of rho's tool_style_test,
# moved with the tables): the catalog's plain set becomes the set a row
# declares — the plain `task`/`ask` only while `nexus` is among its
# styles or no active preset supersedes them, each active preset's alias
# entries beside in `words` order, the row's own description variants
# last — and a `recut` renders against the SERVED template, refusing
# loudly when its anchor moved. The kernel is the one validator of an
# alias (this suite cannot load it): the SHAPE is pinned here, the
# acceptance by the e2e harness (`kernel_tool_names_test`), which renders
# every gem row through the kernel's own refusal.
class ModelAdaptationsStylesTest < Minitest::Test
  PACK = CybrosAgent::ModelAdaptations.load
  PRESETS = PACK.presets
  Styles = CybrosAgent::ModelAdaptations::Styles

  CLAUDE_BACKGROUND =
    "true (the default): the next round continues alongside the task. false: the next round waits " \
    "and the answer is this call's result. Lifetime independently controls whether final delivery waits.".freeze
  CLAUDE_SKILL_PARAMETER = "The skill name. E.g., \"commit\", \"review-pr\", or \"pdf\"".freeze

  def entry(name)
    { "type" => "function",
      "function" => { "name" => name, "description" => "the #{name} verb",
                      "parameters" => { "type" => "object", "properties" => {} } } }
  end

  CATALOG_NAMES = %w[compose task ask memory_read memory_write].freeze

  def catalog = CATALOG_NAMES.map { |name| entry(name) }

  def conversational = catalog + %w[spawn send status cancel].map { |name| entry(name) }

  def names(entries) = entries.map { |entry| entry.dig("function", "name") }

  # A row of the given styles, nothing else (a harness-built row per style
  # id is exactly this shape).
  def row(*styles, **fields)
    PACK.default.with(id: styles.join("+"), tool_style: styles.flatten, **fields)
  end

  # Fake served templates that carry the presets' anchors, so a recut
  # renders without the kernel: HEAD + anchor + TAIL per canonical.
  def templates
    {
      "nexus.graph.task" => "Give one bounded job.\n\n#{anchor("claude", "Agent")}\n\nUse `{{task}}` well.",
      "nexus.conversation.spawn" => "Open a conversation. Its reply reaches you as a `<task_result>` #{anchor("codex", "spawn_agent")}\n\nSpawn early.",
    }
  end

  def anchor(word, name) = alias_spec(word, name).dig("recut", "anchor")

  def alias_spec(word, name) = PRESETS.preset(word).aliases.find { |spec| spec.fetch("name") == name }

  def apply(definitions, *styles, templates: self.templates) = Styles.apply(definitions, row(*styles), presets: PRESETS, templates: templates)

  def test_the_four_words_and_the_nexus_preset_declares_nothing_of_its_own
    assert_equal %w[nexus claude codex workflow], PRESETS.words
    assert_equal PRESETS.words, PRESETS.presets.keys
    assert_empty PRESETS.preset("nexus").aliases
    assert_empty PRESETS.preset("nexus").supersedes
    assert_equal %w[nexus.graph.task nexus.human.ask nexus.skill.load], PRESETS.preset("claude").supersedes
    assert_equal %w[nexus.conversation.spawn nexus.conversation.send nexus.human.ask], PRESETS.preset("codex").supersedes
    assert_equal %w[nexus.graph.compose], PRESETS.preset("workflow").supersedes
    assert_equal({ "Agent" => "claude", "AskUserQuestion" => "claude", "Skill" => "claude",
                   "spawn_agent" => "codex", "send_message" => "codex", "Workflow" => "workflow" }, PRESETS.owners)
  end

  # THE COMPOSE NAME ROW: `Workflow` = compose with
  # the kernel's own text (no description: the name is the question).
  # `workflow` alone withholds plain `compose` and keeps plain `task`/`ask`;
  # `claude` alone keeps plain `compose`; `nexus+workflow` declares both.
  def test_under_workflow_compose_gives_way_to_workflow_and_task_ask_stay_plain
    applied = apply(catalog, "workflow")

    assert_equal %w[task ask memory_read memory_write Workflow], names(applied)
    workflow = applied.fetch(4)
    assert_equal({ "type" => "function", "function" => { "name" => "Workflow" }, "canonical" => "nexus.graph.compose" }, workflow)
    refute workflow.key?("description"), "the kernel's compose template renders under the alias"
    assert_equal %w[compose memory_read memory_write Agent AskUserQuestion], names(apply(catalog, "claude")),
      "claude alone keeps plain compose: the 2026-09-09 cells are unchanged"
    assert_equal %w[compose task ask memory_read memory_write Workflow], names(apply(catalog, "nexus", "workflow"))
    assert_equal %w[memory_read memory_write Agent AskUserQuestion Workflow], names(apply(catalog, "claude", "workflow"))
    without_compose = catalog.reject { |entry| entry.dig("function", "name") == "compose" }
    assert_equal %w[task ask memory_read memory_write], names(apply(without_compose, "workflow")), "a catalog without compose gains no Workflow"
  end

  def test_under_nexus_the_catalog_is_unchanged
    assert_equal catalog, apply(catalog, "nexus")
    assert_equal catalog, PACK.apply(catalog, PACK.row("glm-5.3")), "a row at default's values declares the plain set"
    assert_equal catalog, PACK.apply(catalog, PACK.row("kimi-k3"))
  end

  # `Agent` = task with `run_in_background` (default true; false = wait —
  # the inverted boolean Claude Code trains on) and the served template
  # with ONE anchored edit: the wait paragraph re-cut for a parameter the
  # alias has not; `AskUserQuestion` = ask. No plain `task`/`ask`.
  def test_under_claude_the_plain_task_and_ask_give_way_to_agent_and_ask_user_question
    applied = apply(catalog, "claude")

    assert_equal %w[compose memory_read memory_write Agent AskUserQuestion], names(applied)
    assert_equal catalog.values_at(0, 3, 4), applied.first(3), "compose and the memory verbs stay the catalog's bytes"
    agent = applied.fetch(3)
    assert_equal "nexus.graph.task", agent.fetch("canonical")
    assert_equal({ "run_in_background" => { "maps_to" => "wait", "invert" => true, "description" => CLAUDE_BACKGROUND } },
      agent.fetch("params"))
    assert_equal ["name"], agent.fetch("function").keys, "the compact input spelling: the kernel renders the block"
    refute agent.key?("omit")
    refute agent.key?("recut"), "a recut is rendered, never sent: the kernel's alias grammar has no such key"
    assert_equal "Give one bounded job.\n\n#{alias_spec("claude", "Agent").dig("recut", "replacement")}\n\nUse `{{task}}` well.",
      agent.fetch("description"), "the served template with its one anchored edit"
    assert_includes agent.fetch("description"), "run_in_background: false"
    refute_includes agent.fetch("description"), "wait: true", "the kernel's sentence names a parameter Agent has not"
    assert_includes agent.fetch("description"), "{{task}}", "a macro: the kernel spells it Agent at declaration"
    assert_equal({ "type" => "function", "function" => { "name" => "AskUserQuestion" }, "canonical" => "nexus.human.ask" }, applied.fetch(4))
    assert applied.fetch(3).frozen? && applied.fetch(3).fetch("params").frozen?
  end

  # `spawn_agent` = SPAWN (Codex's `spawn_agent` opens an agent one keeps
  # talking to), `wait` omitted (always detached; a separate wait tool,
  # when exposed, observes the existing task later);
  # `send_message` = SEND in the reference's CURRENT spelling, `target` →
  # `to` (WHERE; the kernel's `agent`, WHO, passes through). Plain `task`
  # STAYS beside them; no ask spelling of its own.
  def test_under_codex_spawn_agent_is_a_spawn_send_message_a_send_and_task_stays_plain
    applied = apply(conversational, "codex")

    assert_equal %w[compose task memory_read memory_write status cancel spawn_agent send_message], names(applied)
    spawn = applied.fetch(6)
    assert_equal "nexus.conversation.spawn", spawn.fetch("canonical")
    assert_equal ["wait"], spawn.fetch("omit")
    refute spawn.key?("params")
    assert_equal "Open a conversation. Its reply reaches you as a `<task_result>` #{alias_spec("codex", "spawn_agent").dig("recut", "replacement")}\n\nSpawn early.",
      spawn.fetch("description")
    assert_includes spawn.fetch("description"), "If `{{wait}}` is available"
    refute_match(/wait: true/, spawn.fetch("description"))
    refute_match(/`to`/, spawn.fetch("description"))
    assert_includes spawn.fetch("description"), "{{spawn}}", "a macro: the kernel spells it spawn_agent at declaration"
    assert_equal({ "type" => "function", "function" => { "name" => "send_message" },
                   "canonical" => "nexus.conversation.send", "params" => { "target" => { "maps_to" => "to" } } },
      applied.fetch(7))
    refute_match(/agent_id/, applied.fetch(7).inspect, "the V1 output field is not a send parameter")
    refute_includes names(applied), "ask", "codex has no ask spelling of its own and the plain one is nexus's"
    assert_equal %w[compose task memory_read memory_write], names(apply(catalog, "codex")), "no spawn in the catalog: no spawn_agent, and task is plain"
    assert_equal %w[compose task ask memory_read memory_write spawn send status cancel spawn_agent send_message],
      names(apply(conversational, "nexus", "codex")), "with nexus the plain spellings stay"
  end

  # THE ANCHOR RULE: a recut needs its template served and its anchor
  # standing in it — a moved anchor or a missing template is `AnchorMoved`
  # naming the entry, never a silent fallback to the plain text.
  def test_a_recut_whose_anchor_moved_or_whose_template_is_not_served_is_refused
    moved = templates.merge("nexus.graph.task" => "Give one bounded job. `wait: true` waits, differently worded.")
    error = assert_raises(CybrosAgent::ModelAdaptations::AnchorMoved) { apply(catalog, "claude", templates: moved) }
    assert_match(/\AAgent: the anchor moved; re-cut the entry: "`wait: true` means your next round WAITS/, error.message)
    error = assert_raises(CybrosAgent::ModelAdaptations::AnchorMoved) { apply(catalog, "claude", templates: {}) }
    assert_match(/\AAgent: no template served for nexus\.graph\.task/, error.message)
    assert_equal %w[compose task ask memory_read memory_write Workflow], names(apply(catalog, "nexus", "workflow", templates: {})),
      "an alias without a recut needs no template"
    assert_raises(CybrosAgent::ModelAdaptations::AnchorMoved) { apply(catalog, "workflow", "claude", templates: {}) }
  end

  def test_two_presets_on_together_declare_both_spellings_in_words_order
    applied = apply(catalog, "claude", "nexus")

    assert_equal %w[compose task ask memory_read memory_write Agent AskUserQuestion], names(applied)
    assert_equal names(apply(catalog, "nexus", "claude")), names(applied), "words order, not the list's"
    assert_equal %w[compose memory_read memory_write status cancel Agent AskUserQuestion spawn_agent send_message],
      names(apply(conversational, "codex", "claude"))
  end

  # A preset aliases only what the catalog fetched: a catalog without `ask`
  # gains no `AskUserQuestion`, one without `task` no `Agent`.
  def test_a_preset_aliases_only_what_the_catalog_carries
    without_ask = catalog.reject { |entry| entry.dig("function", "name") == "ask" }
    assert_equal %w[compose memory_read memory_write Agent], names(apply(without_ask, "claude"))
    assert_equal %w[compose memory_read memory_write], names(apply(without_ask.first(1) + without_ask.last(2), "codex"))
    assert_empty apply([], "nexus", "claude", "codex", "workflow")
  end

  # THE `Skill` ROW: Claude Code's current input shape `{skill}` mapped
  # onto the kernel's `name` with the reference's own sentence; `claude`
  # withholds plain `skill` without `nexus`, `codex` keeps it (no load
  # tool of its own), a catalog without the load gains no `Skill`.
  def test_under_claude_skill_is_spelled_skill_with_claude_codes_parameter_and_plain_skill_withheld
    with_skill = catalog + [entry("skill")]
    applied = apply(with_skill, "claude")

    assert_equal %w[compose memory_read memory_write Agent AskUserQuestion Skill], names(applied)
    assert_equal({ "type" => "function", "function" => { "name" => "Skill" }, "canonical" => "nexus.skill.load",
                   "params" => { "skill" => { "maps_to" => "name", "description" => CLAUDE_SKILL_PARAMETER } } }, applied.last)
    refute applied.last.key?("description"), "the kernel's text renders under the alias"
    assert_equal %w[compose task ask memory_read memory_write skill Agent AskUserQuestion Skill], names(apply(with_skill, "nexus", "claude"))
    assert_equal %w[compose task memory_read memory_write skill], names(apply(with_skill, "codex")), "codex has no load tool: plain skill stays"
    assert_equal %w[compose memory_read memory_write Agent AskUserQuestion], names(apply(catalog, "claude")), "a catalog without the load gains no Skill"
  end

  # A ROW'S OWN DESCRIPTION VARIANTS come last, in the row's order, through
  # the same entry grammar; their names are the row's own, never withheld.
  def test_a_rows_tool_descriptions_join_after_the_presets_aliases
    own = [{ "name" => "Delegate", "canonical" => "nexus.graph.task",
             "recut" => { "anchor" => "Give one bounded job.", "replacement" => "Hand one bounded job over." } }]
    with_own = row("nexus", "workflow", tool_descriptions: own)

    applied = Styles.apply(catalog, with_own, presets: PRESETS, templates: templates)
    assert_equal %w[compose task ask memory_read memory_write Workflow Delegate], names(applied)
    assert applied.last.fetch("description").start_with?("Hand one bounded job over.\n\n`wait: true` means")
    assert_equal %w[Workflow Delegate], names(Styles.alias_entries(with_own, presets: PRESETS, templates: templates))
    assert_equal %w[compose task ask memory_read memory_write Workflow], names(Styles.apply(catalog, with_own.with(tool_descriptions: own.map { |spec| spec.merge("canonical" => "nexus.conversation.spawn") }), presets: PRESETS, templates: templates)),
      "a variant of a tool the catalog lacks is withheld like a preset's alias"
  end

  # Every alias is spelled `function.name` in the SDK helper's compact
  # shape, frozen, with no key the kernel's alias grammar lacks.
  def test_every_alias_entry_is_the_sdk_helpers_compact_shape
    PACK.rows.each do |gem_row|
      Styles.alias_entries(gem_row, presets: PRESETS, templates: templates).each do |entry|
        assert_equal "function", entry.fetch("type")
        assert_equal ["name"], entry.fetch("function").keys
        assert_match(/\Anexus\.(graph|human|conversation|skill)\./, entry.fetch("canonical"))
        assert_empty entry.keys - %w[type function canonical params omit description], entry.inspect
        assert entry.frozen?
      end
    end
  end

  def test_withheld_and_superseded_read_the_tables
    assert Styles.superseded?("nexus.graph.task", ["claude"], presets: PRESETS)
    refute Styles.superseded?("nexus.graph.task", %w[nexus claude], presets: PRESETS)
    refute Styles.superseded?("nexus.graph.task", ["codex"], presets: PRESETS)
    assert Styles.withheld?("task", ["claude"], presets: PRESETS)
    assert Styles.withheld?("Agent", ["nexus"], presets: PRESETS), "an alias is withheld without its preset"
    refute Styles.withheld?("bash", ["claude"], presets: PRESETS), "a runner's tool stays under every style"
    assert_equal %w[task ask skill], Styles.superseded_names(["claude"], presets: PRESETS)
    assert_equal %w[compose], Styles.superseded_names(["workflow"], presets: PRESETS)
    assert_empty Styles.superseded_names(%w[nexus claude codex workflow], presets: PRESETS)
  end
end
