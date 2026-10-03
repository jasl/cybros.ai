require "test_helper"
require "support/pack_fixture"

# THE PACK'S LOADER: the gem's five
# rows and the alias tables load; a kernel `ref` resolves to its row by
# matching the REFERENCE (the ref minus its provider segment) against each
# row's model patterns — the most specific entry answers, else `default`;
# every rule of the format refuses a malformed file by name; every text
# field is honoured as written on a gem row and a local row alike; a LOCAL
# row that replaces no gem row is the operator's own override and answers
# before every gem row. The loader has no catalog and
# no alias-name rule: whether an entry matches a catalog model and whether
# an alias name is reserved are the harness's pins through the kernel.
class ModelAdaptationsLoaderTest < Minitest::Test
  include CybrosAgentTest

  PACK = CybrosAgent::ModelAdaptations.load

  def load_pack(dir, extra: []) = CybrosAgent::ModelAdaptations.load(dir, extra: extra)

  def refusal(rows:, presets: nil, extra: [])
    PackFixture.with_pack(rows: rows, presets: presets) do |dir|
      assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(dir, extra: extra) }
    end
  end

  # THE FIVE ROWS, tiers not a field: `default` is the row with no models;
  # `ids` is the listing order (local rows first), never the resolution's;
  # `source` derived, `gem` on every shipped row; no gem row carries a
  # text — both strong models read the default texts.
  def test_the_gem_ships_five_rows_and_the_tables
    assert_equal %w[claude codex default glm-5.3 kimi-k3], PACK.ids
    assert_equal %w[nexus claude codex workflow], PACK.presets.words
    assert_equal({ "nexus.graph.task" => "task", "nexus.graph.wait" => "wait", "nexus.human.ask" => "ask", "nexus.graph.compose" => "compose",
                   "nexus.conversation.spawn" => "spawn", "nexus.conversation.send" => "send",
                   "nexus.skill.load" => "skill" }, PACK.presets.plain)
    assert PACK.rows.all?(&:gem?)
    assert_empty PACK.local_rows
    assert PACK.default.default?
    assert_equal ["nexus"], PACK.default.tool_style
    assert_equal "on", PACK.default.compose
    assert_predicate PACK.default, :compose?
    PACK.rows.each do |row|
      assert_equal [[], nil], [row.tool_descriptions, row.summarizer_prompt], "#{row.id}: a description or summarizer text on a gem row today"
      assert_equal [], row.lead_hints, "#{row.id}: a hint on a gem row"
    end
    assert_equal({ "glm-5.3" => ["z-ai/glm-5.3"], "kimi-k3" => ["moonshotai/kimi-k3"],
                   "claude" => %w[claude-opus-5-5 claude-fable-5 claude-fable-5-1 claude-sonnet-5],
                   "codex" => %w[gpt-6-astra gpt-6.1-sol gpt-6-luna], "default" => [] },
      PACK.rows.to_h { |row| [row.id, row.models] })
    assert_equal({ "glm-5.3" => ["nexus"], "kimi-k3" => ["nexus"], "claude" => ["claude"], "codex" => ["codex"], "default" => ["nexus"] },
      PACK.rows.to_h { |row| [row.id, row.tool_style] })
    assert PACK.rows.all?(&:compose?)
    assert PACK.rows.all?(&:frozen?)
    assert PACK.row("claude").models.frozen? && PACK.row("claude").tool_style.frozen?
  end

  # KIMI-K3'S ROW CARRIES NO TEXT: the plain names and no lead hint, as glm-5.3's. The row stays,
  # and its entry keeps kimi-k3 off the default row (the tier pins read it), under any lane.
  def test_kimi_k3s_row_reads_the_default_texts
    row = PACK.row("kimi-k3")
    assert_equal [], row.lead_hints
    assert_equal ["nexus"], row.tool_style
    assert_equal ["moonshotai/kimi-k3"], row.models
    %w[openrouter/moonshotai/kimi-k3 or/moonshotai/kimi-k3].each do |ref|
      assert_equal "kimi-k3", PACK.for(ref).id, ref
      assert_empty PACK.for(ref).hint_texts, ref
    end
    assert_empty PACK.for("openrouter/z-ai/glm-5.3").hint_texts
  end

  # AN ENTRY MATCHES A REFERENCE: the provider segment is an operator's
  # lane key and is stripped, so one model resolves to one row under any
  # lane (`or`, `codex_subscription`, `openai_api`); a floor id resolves to
  # `default`, and a broker variant is covered only when a row writes it.
  def test_for_strips_the_provider_segment_and_answers_default_for_the_unlisted
    assert_equal "z-ai/glm-5.3", CybrosAgent::ModelPattern.reference("openrouter/z-ai/glm-5.3")
    assert_equal "glm-5.3", PACK.for("openrouter/z-ai/glm-5.3").id
    assert_equal "glm-5.3", PACK.for("or/z-ai/glm-5.3").id, "an operator-named lane"
    assert_equal "kimi-k3", PACK.for("openrouter/moonshotai/kimi-k3").id
    assert_equal "claude", PACK.for("anthropic/claude-opus-5-5").id
    assert_equal "claude", PACK.for("anthropic/claude-fable-5-1").id, "the references' default Fable model (2026-09-16)"
    assert_equal "codex", PACK.for("openai_api/gpt-6.1-sol").id
    assert_equal "codex", PACK.for("codex_subscription/gpt-6.1-sol").id, "both lanes reach one row by the reference key"
    assert_equal "codex", PACK.for("openai_api/gpt-6-astra").id, "codex's priority-1 model (2026-09-16)"
    assert_equal "codex", PACK.for("codex_subscription/gpt-6-astra").id
    assert_equal "default", PACK.for("anthropic/claude-mythos-5-1").id, "Glasswing-only: never on the row"
    assert_equal "default", PACK.for("openrouter/z-ai/glm-5.3-flash").id, "a floor: never the strong tier's row"
    assert_equal "default", PACK.for("openrouter/deepseek/deepseek-v4.1-flash").id
    assert_equal "default", PACK.for("deepseek/deepseek-flash").id, "the direct floor"
    assert_equal "default", PACK.for("openrouter/anthropic/claude-sonnet-5:exacto").id, "a variant is covered only when a row writes it"
    assert_equal "default", PACK.for("openrouter/openai/gpt-6-sol:exacto").id
    assert_equal "default", PACK.for("codex_subscription/gpt-image-2").id, "an image model on the codex lane: no row names it"
    assert_equal "default", PACK.for("dev/mock-text").id
    assert_equal "default", PACK.for(nil).id
    error = assert_raises(ArgumentError) { PACK.for("glm-5.3") }
    assert_match(/carries no lane segment/, error.message, "a bare reference would fold to default silently")
    assert_nil PACK.row("nope")
  end

  def test_a_pack_needs_a_default_row_and_an_id_equal_to_its_file_name
    refusal(rows: { "glm" => PackFixture.row_yaml("glm", models: ["z-ai/glm-5.3"]) })
    refusal(rows: { "default" => PackFixture.row_yaml("other", models: []) })
    error = PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(extra: { "format" => 2 }) }) do |dir|
      assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(dir) }
    end
    assert_match(/default\.yml: format: expected 1/, error.message)
    assert_equal "format", error.path
  end

  def test_unknown_keys_and_the_settings_only_fields_are_refused_by_name
    error = PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(extra: { "compaction" => { "summarize_after_prunes" => 1 } }) }) do |dir|
      assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(dir) }
    end
    assert_match(/unknown key "compaction"/, error.message, "compaction is not a pack field")
    refusal(rows: { "default" => PackFixture.default_row_yaml(extra: { "tier" => "strong" }) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(extra: { "candidates" => [] }) })
    refusal(rows: { "default" => "format: 1\nrow: default\nmodels: []\ntool_style: [nexus]\n" }, presets: nil)
  end

  # AN ENTRY IS A MODEL PATTERN (`CybrosAgent::ModelPattern`): exact, or
  # one trailing `*` after a separator. A stranger is refused at its index
  # with the helper's reason; one entry on two rows of a source is a load
  # error — the one shape that could tie.
  def test_model_entries_are_patterns_and_one_entry_sits_on_one_row
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml, "g" => PackFixture.row_yaml("g", models: ["z-ai/*"]) }) do |dir|
      assert_equal "g", load_pack(dir).for("lane/z-ai/x").id, "a vendor prefix loads and covers the vendor's references"
    end
    { "z-ai/" => /empty segment/, "z-ai/glm 5.3" => /carries " "/, "z-ai/glm-5.3*" => /puts \* right after "3"/,
      "glm-5\\.3" => /reserved pattern character/, "claude-.*" => /regular expression's "anything"/,
      "*" => /names no letter or digit/ }.each do |entry, reason|
      error = PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml, "g" => PackFixture.row_yaml("g", models: ["claude-x", entry]) }) do |dir|
        assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(dir) }
      end
      assert_equal "models[1]", error.path, entry
      assert_match(reason, error.message, entry)
      assert_includes error.message, "g.yml: models[1]: #{entry.inspect} ", "the entry's own spelling, by index"
    end
    refusal(rows: { "default" => PackFixture.default_row_yaml, "g" => PackFixture.row_yaml("g", models: ["z-ai/glm-5.3", "z-ai/glm-5.3"]) })
    { "z-ai/glm-5.3" => %r{b\.yml: models: "z-ai/glm-5.3" is also on row "a"}, "claude-*" => /b\.yml: models: "claude-\*" is also on row "a"/ }.each do |entry, message|
      error = PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml,
                                            "a" => PackFixture.row_yaml("a", models: [entry]),
                                            "b" => PackFixture.row_yaml("b", models: [entry]) }) do |dir|
        assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(dir) }
      end
      assert_match(message, error.message)
    end
    # The loader has no catalog: an entry it has never heard of loads
    # (the harness pins gem rows against the catalog).
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml, "x" => PackFixture.row_yaml("x", models: ["acme/never"]) }) do |dir|
      assert_equal "x", load_pack(dir).for("lane/acme/never").id
    end
  end

  # OVERLAPPING ENTRIES ON DIFFERENT ROWS ARE A CARVE-OUT: the most
  # specific entry answers — exact over prefix, a longer stem over a
  # shorter — and file order never decides.
  def test_the_most_specific_entry_answers_whatever_the_file_order
    [%w[a b c], %w[z y x]].each do |wide, narrow, exact|
      rows = { "default" => PackFixture.default_row_yaml, wide => PackFixture.row_yaml(wide, models: ["claude-*"]),
               narrow => PackFixture.row_yaml(narrow, models: ["claude-opus-*"]), exact => PackFixture.row_yaml(exact, models: ["claude-opus-5-5"]) }
      PackFixture.with_pack(rows: rows) do |dir|
        pack = load_pack(dir)
        assert_equal exact, pack.for("lane/claude-opus-5-5").id
        assert_equal narrow, pack.for("lane/claude-opus-6").id
        assert_equal wide, pack.for("lane/claude-haiku-5").id
        assert_equal "default", pack.for("lane/anthropic/claude-opus-5-5").id, "the vendor segment is the reference's own bytes"
      end
    end
  end

  def test_tool_style_words_are_the_tables_and_compose_is_on_or_off
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_style: ["gemini"]) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_style: %w[nexus nexus]) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(compose: "auto") })
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(compose: "off"),
                                  "y" => "format: 1\nrow: y\nmodels: [a/b]\ntool_style: [claude, workflow]\ncompose: on\n" }) do |dir|
      pack = load_pack(dir)
      assert_equal "off", pack.default.compose
      assert_equal "on", pack.row("y").compose, "YAML's bare `on` reads as the word"
      assert_equal %w[claude workflow], pack.row("y").tool_style
      assert_equal [], pack.row("y").lead_hints, "the texts default to none"
    end
  end

  # A GEM ROW'S TEXTS ARE THE AUTHOR'S DATA, honoured as written and frozen to the leaf
  # string — the same as a local row's; which run a text was read in is the promoting
  # commit history, not a field.
  def test_a_gem_rows_text_is_honoured_as_written
    hint = [{ "id" => "k6", "text" => "Do not wait for a detached task." }]
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(lead_hints: hint, summarizer_prompt: "Summarize.") }) do |dir|
      row = load_pack(dir).default
      assert_predicate row, :gem?
      assert_equal ["Do not wait for a detached task."], row.hint_texts
      assert_predicate row.lead_hints, :frozen?
      assert_predicate row.lead_hints.first.fetch("text"), :frozen?
      assert_equal "Summarize.", row.summarizer_prompt
    end
    entry = [{ "name" => "Agent", "canonical" => "nexus.graph.task", "description" => "x" }]
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry) }) do |dir|
      assert_equal entry, load_pack(dir).default.tool_descriptions
    end
  end

  # THE OWN-STYLE RULE: a hint's backticked kernel names are the row's own
  # spellings — a plain word the row's styles supersede is refused (the
  # model under `claude` alone never sees `task`); with `nexus` beside, or
  # under a preset that supersedes something else, the word stands.
  def test_a_hint_naming_a_superseded_plain_word_is_refused
    hint = ->(text) { [{ "id" => "h", "text" => text }] }
    error = PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(tool_style: ["claude"], lead_hints: hint.call("Prefer `task` for a review.")) }) do |dir|
      assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(dir) }
    end
    assert_match(/lead_hints\[0\]\.text: names `task`, a plain word the row's styles supersede/, error.message)
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_style: ["codex"], lead_hints: hint.call("Use `spawn` sparingly.")) })
    [%w[nexus claude], ["codex"], ["workflow"]].each do |styles|
      PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(tool_style: styles, lead_hints: hint.call("Prefer `task` for a review; `Agent` too.")) }) do |dir|
        assert_equal ["Prefer `task` for a review; `Agent` too."], load_pack(dir).default.hint_texts, styles.inspect
      end
    end
    refusal(rows: { "default" => PackFixture.default_row_yaml(lead_hints: [{ "id" => "h", "text" => "a" }, { "id" => "h", "text" => "b" }]) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(lead_hints: [{ "id" => "h" }]) })
  end

  # THE ENTRY GRAMMAR, shared by a preset alias and a row's description
  # variant: a text has one source (`description` xor `recut`), a canonical
  # the tables spell, a parameter map onto a kernel word.
  def test_a_description_entry_keeps_the_alias_grammar
    entry = ->(**fields) { [{ "name" => "Agent", "canonical" => "nexus.graph.task" }.merge(fields.transform_keys(&:to_s))] }
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(description: "x", recut: { "anchor" => "a", "replacement" => "b" })) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(recut: { "anchor" => "a" })) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(canonical: "nexus.memory.read", description: "x")) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(params: { "bg" => { "invert" => true } }, description: "x")) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(params: { "bg" => { "maps_to" => "wait", "flip" => true } }, description: "x")) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(other: 1, description: "x")) })
    refusal(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(description: "x") * 2) })
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml(tool_descriptions: entry.call(recut: { "anchor" => "a", "replacement" => "b" }, omit: ["wait"])) }) do |dir|
      row = load_pack(dir).default
      assert_equal({ "anchor" => "a", "replacement" => "b" }, row.tool_descriptions.first.fetch("recut"))
    end
  end

  def test_the_tables_are_validated_too
    presets = File.read(File.join(PackFixture::GEM_DIR, "presets.yml"), encoding: Encoding::UTF_8)
    refusal(rows: { "default" => PackFixture.default_row_yaml }, presets: presets.sub("format: 1", "format: 2"))
    refusal(rows: { "default" => PackFixture.default_row_yaml }, presets: presets.sub("words: [nexus, claude, codex, workflow]", "words: [nexus, claude, codex]"))
    refusal(rows: { "default" => PackFixture.default_row_yaml }, presets: presets.sub("supersedes: [nexus.graph.compose]", "supersedes: [nexus.memory.read]"))
    refusal(rows: { "default" => PackFixture.default_row_yaml }, presets: presets.sub("name: Workflow, canonical", "name: Agent, canonical"))
    refusal(rows: { "default" => PackFixture.default_row_yaml }, presets: "format: 1\nwords: [nexus]\nplain: {}\npresets: {nexus: {supersedes: [], aliases: []}}\nextra: 1\n")
    refusal(rows: { "default" => PackFixture.default_row_yaml }, presets: "format: 1\nwords: [nexus]\nplain: {a: x, b: x}\npresets: {nexus: {supersedes: [], aliases: []}}\n")
    refusal(rows: { "default" => PackFixture.default_row_yaml }, presets: "format: 1\nwords: [nexus\n")
  end

  # LOCAL ROWS are the operator's. One that replaces no gem row is its OWN
  # per-model override and answers before every gem row, the gem's exact
  # entries included; one of a gem row's id replaces that row in place.
  # Printed `local`. Two local rows on one entry are still a load error.
  def test_a_local_row_carries_its_texts_and_beats_the_gem_row
    mine = PackFixture.row_yaml("mine", models: ["z-ai/glm-5.3"], tool_style: %w[claude workflow],
      lead_hints: [{ "id" => "k6", "text" => "Never wait on a detached `Agent`." }], summarizer_prompt: "Summarize as pointers.", compose: "off")
    PackFixture.with_local_row("mine", mine) do |path, dir|
      [[path], [dir]].each do |extra|
        pack = load_pack(PackFixture::GEM_DIR, extra: extra)
        row = pack.for("openrouter/z-ai/glm-5.3")
        assert_equal "mine", row.id
        assert_predicate row, :local?
        assert_equal ["Never wait on a detached `Agent`."], row.hint_texts
        assert_equal "Summarize as pointers.", row.summarizer_prompt
        assert_equal "off", row.compose
        assert_equal %w[mine claude codex default glm-5.3 kimi-k3], pack.ids, "local rows first, then the gem's"
        assert_equal ["mine"], pack.local_rows.map(&:id)
        assert_equal "glm-5.3", pack.row("glm-5.3").id, "the gem row stays loadable by id"
      end
    end
    PackFixture.with_local_row("default", PackFixture.default_row_yaml(compose: "off")) do |path, _dir|
      pack = load_pack(PackFixture::GEM_DIR, extra: [path])
      assert_equal "off", pack.default.compose, "a local row of a gem row's id replaces it"
      assert_predicate pack.default, :local?
      assert_equal 5, pack.rows.size
    end
    PackFixture.with_local_row("a", PackFixture.row_yaml("a", models: ["x/y"])) do |a, _dir|
      PackFixture.with_local_row("b", PackFixture.row_yaml("b", models: ["x/y"])) do |b, _dir|
        assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(PackFixture::GEM_DIR, extra: [a, b]) }
      end
    end
    PackFixture.with_local_row("a", PackFixture.row_yaml("a", models: ["claude-*"])) do |a, _dir|
      PackFixture.with_local_row("b", PackFixture.row_yaml("b", models: ["claude-*"])) do |b, _dir|
        assert_raises(CybrosAgent::ModelAdaptations::Invalid) { load_pack(PackFixture::GEM_DIR, extra: [a, b]) }
      end
    end
  end

  # THE OWN TIER: an operator's `z-ai/*` takes every `z-ai/` reference, the
  # gem's exact glm-5.3 included, and nothing else; two own rows carve out
  # by specificity in either path order.
  def test_an_own_local_row_answers_before_every_gem_row
    PackFixture.with_local_row("mine", PackFixture.row_yaml("mine", models: ["z-ai/*"])) do |path, _dir|
      pack = load_pack(PackFixture::GEM_DIR, extra: [path])
      assert_equal "mine", pack.for("openrouter/z-ai/glm-5.3").id, "the operator's override beats the gem's exact entry"
      assert_equal "mine", pack.for("openrouter/z-ai/glm-5.3-flash").id, "the operator's own deployment"
      assert_equal "kimi-k3", pack.for("openrouter/moonshotai/kimi-k3").id
      assert_predicate pack.for("openrouter/moonshotai/kimi-k3"), :gem?, "the gem row, untouched by the operator's"
      assert_equal "claude", pack.for("anthropic/claude-opus-5-5").id
    end
    PackFixture.with_local_row("wide", PackFixture.row_yaml("wide", models: ["claude-*"])) do |wide, _dir|
      PackFixture.with_local_row("opus", PackFixture.row_yaml("opus", models: ["claude-opus-*"])) do |opus, _dir|
        [[wide, opus], [opus, wide]].each do |extra|
          pack = load_pack(PackFixture::GEM_DIR, extra: extra)
          assert_equal "opus", pack.for("anthropic/claude-opus-5-5").id, extra.inspect
          assert_equal "wide", pack.for("anthropic/claude-sonnet-5").id, extra.inspect
          assert_equal "codex", pack.for("openai_api/gpt-6.1-sol").id
        end
      end
    end
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml, "a" => PackFixture.row_yaml("a", models: ["claude-*"]) }) do |dir|
      PackFixture.with_local_row("b", PackFixture.row_yaml("b", models: ["claude-*"])) do |path, _dir|
        assert_equal "b", load_pack(dir, extra: [path]).for("lane/claude-x").id
      end
    end
  end

  # THE STANDING TIER: a local row of a gem row's id stands in that row's
  # place, so writing a gem row back as a local copy — the evals' candidate
  # door — moves no reference; on an entry shared with another gem row the
  # local row wins the tie.
  def test_a_gem_row_rewritten_as_a_local_row_of_its_id_moves_no_reference
    gem = { "default" => PackFixture.default_row_yaml, "fam" => PackFixture.row_yaml("fam", models: ["moonshotai/kimi-*"]),
            "k3" => PackFixture.row_yaml("k3", models: ["moonshotai/kimi-k3"]) }
    PackFixture.with_pack(rows: gem) do |dir|
      PackFixture.with_local_row("fam", PackFixture.row_yaml("fam", models: ["moonshotai/kimi-*"])) do |path, _dir|
        pack = load_pack(dir, extra: [path])
        assert_equal %w[k3 gem], [pack.for("lane/moonshotai/kimi-k3").id, pack.for("lane/moonshotai/kimi-k3").source]
        assert_equal %w[fam local], [pack.for("lane/moonshotai/kimi-k4").id, pack.for("lane/moonshotai/kimi-k4").source]
      end
    end
    refs = %w[openrouter/z-ai/glm-5.3 openrouter/z-ai/glm-5.3-flash openrouter/moonshotai/kimi-k3 anthropic/claude-opus-5-5
              openai_api/gpt-6.1-sol codex_subscription/gpt-6-astra deepseek/deepseek-flash dev/mock-text]
    PACK.gem_rows.each do |row|
      copy = PackFixture.row_yaml(row.id, models: row.models.to_a, tool_style: row.tool_style.to_a,
        lead_hints: row.lead_hints.map(&:to_h), compose: row.compose)
      PackFixture.with_local_row(row.id, copy) do |path, _dir|
        pack = load_pack(PackFixture::GEM_DIR, extra: [path])
        assert_equal refs.map { |ref| PACK.for(ref).id }, refs.map { |ref| pack.for(ref).id }, "#{row.id} copied local"
      end
    end
    PackFixture.with_pack(rows: { "default" => PackFixture.default_row_yaml, "a" => PackFixture.row_yaml("a", models: ["claude-*"]),
                                  "b" => PackFixture.row_yaml("b", models: ["claude-opus-*"]) }) do |dir|
      PackFixture.with_local_row("b", PackFixture.row_yaml("b", models: ["claude-*"])) do |path, _dir|
        pack = load_pack(dir, extra: [path])
        row = pack.for("lane/claude-x")
        assert_equal %w[b local], [row.id, row.source], "a replacement sharing a gem row's entry wins the tie"
        # The loader lists the local row first; the gem row listed first must lose the tie too.
        [pack.rows, pack.rows.reverse].each do |rows|
          row = CybrosAgent::ModelAdaptations::Pack.new(presets: pack.presets, rows: rows, gem_ids: %w[a b default]).for("lane/claude-x")
          assert_equal %w[b local], [row.id, row.source], "the local row wins the tie whatever the listing order"
        end
      end
    end
  end
end
