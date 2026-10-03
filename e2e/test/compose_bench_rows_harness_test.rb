require_relative "compose_bench_harness"
require "digest"
require "minitest/mock"
require "set"
require "support/screen/stems"

# THE ROWS AND THEIR PINS: a style re-spells the row's text through the kernel's renderer, a
# candidate joins the probe's instructions and keys its cell, the shipped row is the registry's
# bytes with every landed edit at its place, its nested-stage example builds and reduces, and a
# re-cut's moved anchor is loud.
class ComposeBenchRowsHarnessTest < Minitest::Test
  include ComposeBenchHarness

  # THE STYLE AXIS: a style's declared set is the harness's five tools plus the style's `task` and
  # `ask` entries — `nexus` the catalog's plain bytes, `claude`/`codex` rho's presets — rendered
  # through the KERNEL's renderer, never a harness copy; and the row's compose text is rendered
  # under the SAME set, so `{{task}}` in compose's text spells the style's name. `nexus` is the
  # same-day baseline: its bytes are the shipped bytes exactly. Two presets on at once is a style of
  # its own (`nexus+claude`): the preference rule keeps the plain name in compose's text when it is
  # declared.
  def test_a_style_declares_its_task_and_ask_beside_compose_and_respells_composes_text
    row = Rows.find("shipped")
    nexus = Styles.find("nexus")
    assert_equal %w[nexus], nexus.words
    assert_equal Tools::NAMES + %w[task ask], nexus.names
    assert_equal [Nexus::ToolRegistry.function_definition("nexus.graph.task"),
                  Nexus::ToolRegistry.function_definition("nexus.human.ask")],
      nexus.kernel_entries, "the catalog's plain bytes, untouched"
    assert_equal row.definition, nexus.definition_for(row), "the nexus style is the shipped bytes"
    assert_equal Tools.function_definitions + nexus.kernel_entries, nexus.declared, "the manifest's tools"

    claude = Styles.find("claude")
    assert_equal Tools::NAMES + %w[Agent AskUserQuestion], claude.names
    agent = claude.kernel_entries.first
    assert_equal "nexus.graph.task", agent["canonical"]
    assert_equal %w[prompt lifetime wake run_in_background tools], agent.dig("function", "parameters", "properties").keys
    assert_equal true, agent.dig("function", "parameters", "properties", "run_in_background", "default")
    assert_includes agent.dig("function", "description"), "`run_in_background: false` means your next round WAITS"
    refute_includes agent.dig("function", "description"), "{{", "rendered: no macro survives"
    compose_text = claude.definition_for(row).dig("function", "description")
    assert_includes compose_text, "you need neither compose nor\nAgent. When you will read the answers yourself"
    refute_includes compose_text, "nor\ntask"
    assert_equal row.template.gsub("{{task}}", "Agent").gsub("{{compose}}", "compose"), compose_text,
      "every task macro is re-spelled, while the rest of the description stays unchanged"

    # RE-LABELLED: codex re-spells the kernel's SPAWN and SEND, which the compose matrix does not
    # declare, so its cell here is the plain `task` with no ask — the codex spelling's measurement
    # is the task bench's SP rows and the evals' spawn family.
    codex = Styles.find("codex")
    assert_equal Tools::NAMES + %w[task], codex.names
    assert_equal [Nexus::ToolRegistry.function_definition("nexus.graph.task")], codex.kernel_entries
    assert_includes codex.definition_for(row).dig("function", "description"), "neither compose nor\ntask"

    both = Styles.find("nexus+claude")
    assert_equal %w[nexus claude], both.words
    assert_equal Tools::NAMES + %w[task ask Agent AskUserQuestion], both.names
    assert_includes both.definition_for(row).dig("function", "description"), "neither compose nor\ntask",
      "the preference rule: the plain name when it is declared"

    assert_raises(ArgumentError) { Styles.find("gemini") }
    assert_raises(ArgumentError) { Styles.find("") }
    assert_equal %w[nexus], E2E::ComposeBench::STYLES.map(&:id), "the default axis is the baseline alone"
  end

  # THE CANDIDATE AXIS (the RUN step's text probes): `E2E_BENCH_CANDIDATES=<row>/<id>,…` loads
  # `lead_hints` candidates of the harness's candidate files — a hint's line joins the probe's
  # instructions after SYSTEM, the declared set is untouched, the sample carries the key — each on
  # the models its row covers (the probes spell the catalog's model refs, and the pack resolves a
  # ref to its row the way the daemon does); an unknown key, another kind, or a candidate covering
  # no selected model is refused before a call is paid; none named is the baseline alone. No
  # candidate is on file, so the axis is read through the test's own: a hint of kimi's row and a
  # word of glm's, handed to the loader in place of the files.
  HINT = E2E::AdaptationRows::Candidate.new(row_id: "kimi-k3", id: "test-hint", kind: "lead_hints", payload: "The test's line.",
    seed: "the test's own; never a file")
  WORD = E2E::AdaptationRows::Candidate.new(row_id: "glm-5.3", id: "test-word", kind: "tool_style", payload: ["workflow"],
    seed: "the test's own; never a file")

  def test_a_lead_hints_candidate_joins_the_probes_instructions_and_keys_the_cell
    rows = E2E::AdaptationRows
    kimi = HINT
    unknown = assert_raises(ArgumentError) { rows.list("kimi-k3/k6-detached-fan-is-never-waited", kinds: %w[lead_hints]) }
    assert_equal %(no candidate "kimi-k3/k6-detached-fan-is-never-waited": the candidates are none (e2e/evals/candidates/)), unknown.message,
      "deleted: the door stands with no candidate"
    assert_equal [], rows.list(nil, kinds: %w[lead_hints])
    rows.stub(:candidates, { WORD.key => WORD, HINT.key => HINT }) do
      assert_equal [kimi], rows.list(" kimi-k3/test-hint, ", kinds: %w[lead_hints])
      kind = assert_raises(ArgumentError) { rows.list(WORD.key, kinds: %w[lead_hints]) }
      assert_match(/is a tool_style candidate; this probe reads lead_hints/, kind.message)
      named = assert_raises(ArgumentError) { rows.list("glm-5.3/nope", kinds: %w[lead_hints]) }
      assert_match(%r{no candidate "glm-5.3/nope": the candidates are glm-5.3/test-word, kimi-k3/test-hint}, named.message)
    end
    assert_equal({ "openrouter/z-ai/glm-5.3" => [nil], "openrouter/moonshotai/kimi-k3" => [kimi], "openrouter/z-ai/glm-5.3-flash" => [nil] },
      rows.cells([kimi], %w[openrouter/z-ai/glm-5.3 openrouter/moonshotai/kimi-k3 openrouter/z-ai/glm-5.3-flash]),
      "the candidate on the models its row covers; a model no candidate covers keeps its baseline cell")
    assert_equal({ "openrouter/z-ai/glm-5.3" => [nil] }, rows.cells([], %w[openrouter/z-ai/glm-5.3]))
    assert_equal "glm-5.3", rows.probe_row("openrouter/z-ai/glm-5.3").id, "a ref reads its row whatever lane serves it"
    assert_equal "default", rows.probe_row("openrouter/z-ai/glm-5.3-flash").id, "a floor reads the default row"
    assert_equal "default", rows.probe_row("deepseek/deepseek-flash").id, "the direct floor too"
    covers = assert_raises(ArgumentError) { rows.cells([kimi], %w[openrouter/z-ai/glm-5.3]) }
    assert_match(%r{kimi-k3/test-hint covers none of openrouter/z-ai/glm-5.3}, covers.message)
    assert_equal({}, E2E::ComposeBench::CANDIDATES.to_h { |c| [c.key, c] }, "no E2E_BENCH_CANDIDATES: the baseline")
    assert E2E::ComposeBench::CELLS.values.all? { |cells| cells == [nil] }
    assert_equal E2E::Evals::Bench.read.tiers.fetch("floor"), E2E::ComposeBench::WEAK_MODELS,
      "no E2E_BENCH_MODELS: the evals' own floor, the direct DeepSeek lane first"

    kimi_k3 = E2E::ProviderLanes.route("openrouter/moonshotai/kimi-k3")
    probe = E2E::ComposeBench::Probe.new(client: nil, route: kimi_k3, row: Rows.find("shipped"), candidate: kimi)
    assert_equal "#{E2E::ComposeBench::Probe::SYSTEM}\n\n#{kimi.payload}", probe.instructions
    assert_equal E2E::ComposeBench::Probe::SYSTEM, E2E::ComposeBench::Probe.new(client: nil, route: kimi_k3, row: Rows.find("shipped")).instructions
    assert_includes probe.instructions, "The test's line."

    # The readout keys the cell by the candidate: its own table, stem and
    # manifest entry; the baseline's spellings never move.
    sample = lambda do |candidate, index|
      { "objective" => "O2", "row" => "R-WO", "model" => "moonshotai/kimi-k3", "candidate" => candidate, "sample" => index, "reached" => true,
        "valid_first" => true, "first_time_right" => true, "script" => CANONICAL.fetch("O2"), "params" => {}, "called" => { "compose" => 1 } }.compact
    end
    Dir.mktmpdir("bench") do |dir|
      captures = File.join(dir, "captures")
      E2E::ComposeBench::Report.write_all([sample.call(nil, 1), sample.call(kimi.key, 1)], dir: dir, captures: captures)
      assert_equal %w[results-r-wo-moonshotai-kimi-k3-nexus-kimi-k3-test-hint.md results-r-wo-moonshotai-kimi-k3-nexus.md],
        Dir.children(dir).grep(/\Aresults-/).sort
      table = File.read(File.join(dir, "results-r-wo-moonshotai-kimi-k3-nexus-kimi-k3-test-hint.md"), encoding: Encoding::UTF_8)
      assert_includes table, "style `nexus`, candidate `kimi-k3/test-hint`"
      assert_equal %w[o2.r-wo.moonshotai-kimi-k3.1.js o2.r-wo.moonshotai-kimi-k3.kimi-k3-test-hint.1.js],
        Dir.children(captures).grep(/\.js\z/).sort
      manifest = JSON.parse(File.read(File.join(captures, "manifest.json"), encoding: Encoding::UTF_8))
      assert_equal [nil, kimi.key], manifest.map { |entry| entry["candidate"] }
      E2E::ComposeBench::Report.write_all([sample.call(kimi.key, 1).merge("script" => "again")], dir: dir, captures: captures)
      matrix = JSON.parse(File.read(File.join(dir, "compose_matrix.json"), encoding: Encoding::UTF_8))
      assert_equal [[nil, CANONICAL.fetch("O2")], [kimi.key, "again"]], matrix.map { |s| [s["candidate"], s["script"]] },
        "a candidate cell replaces its own samples and keeps the baseline's"
    end
  end

  # THE FLOOR IS NEVER TUNED FOR, AT RUN TIME TOO: were a gem row's entries to reach a floor model
  # (`z-ai/glm-*` takes `z-ai/glm-5.3-flash`), a candidate of that row paired with the floor is
  # refused before a call is paid, in the evals door's words; the floor's baseline cell stands.
  def test_a_candidate_paired_with_a_floor_model_is_refused_before_a_call
    rows = E2E::AdaptationRows
    glm = rows.pack.row("glm-5.3").with(models: ["z-ai/glm-*"])
    widened = CybrosAgent::ModelAdaptations::Pack.new(presets: rows.pack.presets, rows: [glm, rows.pack.default],
      gem_ids: [glm.id, rows.pack.default.id])
    candidate = rows::Candidate.new(row_id: "glm-5.3", id: "test-hint", kind: "lead_hints", payload: "The test's line.",
      seed: "the test's own; never a file")
    rows.stub(:pack, widened) do
      assert_equal "glm-5.3", rows.probe_row("openrouter/z-ai/glm-5.3-flash").id, "the stub reaches the floor"
      refused = assert_raises(ArgumentError) do
        rows.cells([candidate], %w[openrouter/z-ai/glm-5.3 openrouter/z-ai/glm-5.3-flash])
      end
      assert_equal "glm-5.3/test-hint: openrouter/z-ai/glm-5.3-flash is on the floor tier (read-only, never tuned for)",
        refused.message
      assert_equal({ "openrouter/z-ai/glm-5.3" => [candidate], "deepseek/deepseek-flash" => [nil] },
        rows.cells([candidate], %w[openrouter/z-ai/glm-5.3 deepseek/deepseek-flash]), "a floor the candidate's row misses keeps its baseline")
      assert_equal({ "openrouter/z-ai/glm-5.3-flash" => [nil] }, rows.cells([], %w[openrouter/z-ai/glm-5.3-flash]),
        "the floor's baseline cell stands")
    end
  end

  # A NAMED FLOOR IS A FLOOR HERE TOO: the bench's `named_only` floor rides its family's gem row with
  # no stub at all, so the tier — read through the bench's one `tier_of`, never its roster alone —
  # is what refuses the pair; the strong model on the same row keeps its candidate.
  def test_a_candidate_paired_with_a_named_floor_model_is_refused_before_a_call
    rows = E2E::AdaptationRows
    candidate = rows::Candidate.new(row_id: "codex", id: "test-hint", kind: "lead_hints", payload: "The test's line.",
      seed: "the test's own; never a file")
    assert_equal "codex", rows.probe_row("openai_api/gpt-6-luna").id, "the pack's own resolution"
    refused = assert_raises(ArgumentError) { rows.cells([candidate], %w[openai_api/gpt-6.1-sol openai_api/gpt-6-luna]) }
    assert_equal "codex/test-hint: openai_api/gpt-6-luna is on the floor tier (read-only, never tuned for)", refused.message
    assert_equal({ "openai_api/gpt-6.1-sol" => [candidate] }, rows.cells([candidate], %w[openai_api/gpt-6.1-sol]))
  end

  # A row is a TEMPLATE the styles re-spell: its description is the plain
  # render (the pin below reads it), and a re-cut applied to the plain
  # text alone is a row with no macros left to re-spell.
  def test_a_row_is_a_template_whose_description_is_the_plain_render
    row = Rows.find("shipped")
    assert_equal Nexus::ToolRegistry.entry("nexus.graph.compose").template, row.template
    assert_equal Nexus::ToolRegistry.render_text(row.template), row.description
    assert_equal 6, row.template.scan("{{task}}").length,
      "the choice of tool, the three task rungs and both inherited-tool clauses use the declared spelling"
    assert_equal row.definition, row.definition({}), "no spellings: the plain definition"
    assert_includes row.definition({ "task" => "Agent" }).dig("function", "description"), "nor\nAgent"

    plain = Rows::Row.new(id: "R-X", description: "no macro here")
    assert_equal "no macro here", plain.template
    assert_equal "no macro here", plain.definition({ "task" => "Agent" }).dig("function", "description")
  end

  # The benchmark baseline is the shipped registry text. Pin the read clause, the examples,
  # background default, fan sentence, verb line, the result's call sentence, the race reference and
  # its reader, the g.wait read, the boundary paragraph and a stage's declared reads at their
  # anchors; compile the examples and check the total bytes so accidental prompt edits are visible.
  def test_the_shipped_row_is_the_registry_bytes_and_carries_each_landed_edit
    shipped = Rows.find("shipped").description
    assert_equal Nexus::ToolRegistry.wire_schema_for("compose").fetch("description"), shipped
    assert_equal "compose", Rows.find("shipped").definition.dig("function", "name")
    assert_equal 16, Rows::LANDED.length,
      "the read clause, the pipeline line, delivery and wait sentences, lifetime, wake, fan sentence, verb table, " \
      "a stage's params, the race reference and its reader, a race's stage slot, the result's call, the g.wait " \
      "read, the peers example, the boundary paragraph and a stage's declared reads"
    Rows::LANDED.each { |name, text| assert_equal 1, shipped.scan(text).length, name }
    assert_includes shipped, "inside one g.parallel([...]) run at the same time.\n#{Rows::READ_CLAUSE}" \
                             "#{Rows::CALL_SENTENCE}#{Rows::RACE_REFERENCE}#{Rows::WAIT_READ_CLAUSE}",
      "the read clause follows the ORDER sentences, the call sentence follows the read sentences, and the race " \
      "reference, closed by its reader, comes before the g.wait read"
    assert_includes shipped, "the handle itself has neither.\n#{Rows::STAGE_READS_SENTENCE}\nA stage either returns",
      "a stage's declared reads close the envelope paragraph"
    assert_equal 1, shipped.scan(Rows::VERB_TABLE).length, "one verb table, no WHEN word on a step"
    assert_includes shipped, "#{Rows::ORDER_ANCHOR}\n#{Rows::FAN_SENTENCE}",
      "the fan sentence continues the ORDER paragraph, no blank line"
    assert_includes shipped, "{ until? }", "the fan's join word is until"
    refute_includes shipped, "{ wait? }", "the fan's old word is gone from the verb line"
    refute_includes shipped, "never false", "the boolean clause went with the word no boolean fits"
    refute_includes shipped, "a fan's wait chooses", "the collision's own explanation went with the collision"
    refute_includes shipped, "first success", "the fan's until is spelled as how many successes end the fan"
    refute_includes shipped, "back to the previous model step", "no step reads what ran before it"
    refute_includes shipped, "accumulated results", "a group's members reach a step only when named"
    refute_includes shipped, "Sibling parallel members", "a member reads only what it is handed, like every step"
    refute_includes shipped, "remains available to the main conversation", "a named tool is read, not delivered"
    refute_includes shipped, "model history", "no step sees another step's conversation"
    assert_equal 1, shipped.scan(Rows::EXAMPLE_BLOCK_START).length, "the example block opens on the handles its fan groups"
    assert_includes shipped, "STEPS RUN IN THE ORDER YOU WRITE THEM", "the ORDER paragraph stays"
    assert_includes shipped, "one `task` call, never a one-step `compose`", "paragraph 1 sends a long command to task"
    assert_includes shipped, "To compute from future output without a model round, place g.script.",
      "a future result is read by a later script stage"
    assert_includes shipped, "A model step with no `model:` runs as the model you are", "the no-model paragraph stays"
    refute_includes shipped, "run_in_background", "the deleted word is gone from the bytes"
    refute_includes shipped, "write it after the g.parallel. That is the only wiring", "the pre-freeze sibling sentence is gone"
    assert shipped.end_with?(Rows::WAKE_PARAGRAPH), "the wake paragraph closes the text"
    assert_equal 9768, shipped.bytesize, "intentional capability wording changes must update this byte pin"
    assert_equal "9d19cc6bff68f3e0046fb052372c461dbe0e77fd7245ff1973e5db0f4f7676c5", Digest::SHA256.hexdigest(shipped),
      "current shipped door guidance and supplementary-turn delivery contract"
    assert_includes shipped, "and `error`.\n#{Rows::RACE_SLOT}Check failure before parsing.",
      "a race's slot closes the envelope sentence, before the failure check"

    race = evaluate(<<~JS)
      const a = g.tool({ name: "bash", input: { command: "bin/probe alpha" } });
      const b = g.tool({ name: "bash", input: { command: "bin/probe bravo" } });
      const c = g.tool({ name: "bash", input: { command: "bin/probe charlie" } });
      #{Rows::RACE_REFERENCE[/`(const race = [^`]*)`/, 1]};
      g.script({ results: [race], script: "return results[0].output;" });
    JS
    assert_predicate race, :built?, "the race example must itself be a script the builder accepts: #{race.detail}"
    assert_equal ["parallel-1"], race.steps.last.dig("script", "results")

    pipeline = evaluate(Rows::NESTED_EXAMPLE)
    assert_predicate pipeline, :built?, "the pipeline example must itself be a script the builder accepts: #{pipeline.detail}"
    pairs = pipeline.steps.sole.fetch("parallel")
    assert_equal 2, pairs.length
    pairs.each do |run, reader|
      assert_equal [run.dig("tool", "key")], reader.dig("model", "results"), "each model step is handed only its own run"
    end
  end

  def test_the_shipped_script_example_builds_and_reduces_inside_one_result_boundary
    examples = Rows.shipped.scan(/^  g\.script\(\{script: `\n.*?^  `\}\);$/m)
    assert_equal 1, examples.length, "one complete nested-stage example must be available to the model"
    built = evaluate(examples.sole)
    assert_predicate built, :built?, built.detail
    assert_equal ["script"], built.steps.map { |step| step.keys.sole }
    outer = built.steps.sole.fetch("script")
    expanded = Nexus::Compose::Evaluator.stage(script: outer.fetch("script"), tool_names: Tools::NAMES)
    assert_predicate expanded, :built?, expanded.detail
    assert_predicate expanded, :steps?
    assert_equal %w[tool script], expanded.steps.map { |step| step.keys.sole }
    read = expanded.steps.first.fetch("tool")
    reducer = expanded.steps.last.fetch("script")
    assert_equal "bash", read.fetch("name")
    assert_equal({ "command" => "git diff" }, read.fetch("input"))
    assert_equal [read.fetch("key")], reducer.fetch("results")

    result = { "status" => "completed", "is_error" => false, "output" => "the actual patch",
               "content" => [], "structured_content" => nil, "error" => nil }
    reduced = Nexus::Compose::Evaluator.stage(script: reducer.fetch("script"), results: [result])
    assert_predicate reduced, :value?, reduced.detail
    assert_equal({ "patch" => "the actual patch" }, reduced.value)
    assert_empty reduced.steps
    [result.merge("status" => "failed"), result.merge("is_error" => true)].each do |failure|
      refused = Nexus::Compose::Evaluator.stage(script: reducer.fetch("script"), results: [failure])
      assert_equal :script_error, refused.refusal
      assert_includes refused.detail, "git diff failed"
      assert_empty refused.steps, "failure cannot publish a partial graph"
    end
  end

  # EVERY EXAMPLE A ROW SHOWS IS A SCRIPT THE BUILDER ACCEPTS: a model copies an example whole, so
  # each indented block of every row — the verb table aside — builds, and every model step in it
  # names what it reads, since a step naming nothing reads its prompt alone. The one exception is a
  # step a group briefs alone, first in its member, that a later step names: a panel's member, whose
  # reader names them all. A step behind another in its member's chain still names what it reads.
  def test_every_example_a_row_shows_builds_and_names_each_model_steps_reads
    Rows.all.each do |row|
      blocks = examples(row.description)
      assert_equal 5, blocks.length, "#{row.id}: the checks and the question, the pipeline, the peers, the panel and the stage"
      blocks.each do |block|
        built = evaluate(block)
        assert_predicate built, :built?, "#{row.id}: #{built.detail}\n#{block}"
        read = read_keys(built.steps)
        alone = briefed_alone(built.steps)
        model_steps(built.steps).each do |model|
          panelist = alone.include?(model) && read.include?(model.fetch("key"))
          assert Array(model["results"]).any? || panelist,
            "#{row.id}: #{model.fetch("prompt")[0, 40]} names what it reads, or is a group's member a later step names"
        end
      end
    end
  end

  # The exception is no wider than the panel: a model step behind a run in its member's chain, read
  # by a later step, still has to name the run it follows.
  def test_a_chain_step_read_by_a_later_step_still_names_what_it_reads
    built = evaluate(<<~JS)
      const out = g.parallel(["a", "b"].map((dir) => [
        g.tool({ name: "bash", input: { command: "bin/rails test " + dir } }),
        g.model({ prompt: "Summarize the failures." }),
      ]));
      g.model({ prompt: "Combine the summaries.", results: out.map((c) => c[c.length - 1]) });
    JS
    assert_predicate built, :built?, built.detail
    summaries = model_steps(built.steps).first(2)
    assert_equal %w[model-1 model-2], summaries.map { |model| model.fetch("key") }
    assert_equal summaries.map { |model| model.fetch("key") }, read_keys(built.steps), "the reader names both"
    assert_empty briefed_alone(built.steps), "neither is briefed alone: each follows its run"
  end

  # A variant is named edits over the shipped bytes, each anchored on an exact sentence. A moved
  # anchor raises instead of silently returning the baseline; variants using unsupported grammar
  # cannot be scored. The text without explicit reads, R-WO, is no row on this tree: it is the
  # shipped row of the tree whose kernel it describes, and a pair reads each row on its own tree.
  # The variants the shipped text was screened against are deleted: the registry is the one text.
  def test_a_re_cut_is_anchored_on_the_shipped_bytes_and_a_moved_anchor_is_loud
    assert_equal [Rows::SHIPPED_ID], Rows.ids
    Rows.all.each do |row|
      assert_equal Nexus::ToolRegistry.render_text(row.template), row.description, "#{row.id}: the template and the plain text are cut alike"
    end
    shipped = Rows.find("shipped").description
    line = "  g.ask({ prompt: \"Ship it?\" });\n"
    recut = Rows.recut(shipped, Rows::EXAMPLE_BLOCK_END, "#{Rows::EXAMPLE_BLOCK_END}#{line}")
    assert_equal [line], recut.lines - shipped.lines
    assert_empty shipped.lines - recut.lines
    assert_equal "compose", Rows::Row.new(id: "R-X", description: recut).definition.dig("function", "name")

    moved = assert_raises(ArgumentError) do
      Rows.recut(shipped, "write it after the g.parallel. That is the only wiring", "x")
    end
    assert_includes moved.message, "the anchor moved; re-cut the row"
    moved = assert_raises(ArgumentError) { Rows.recut(shipped, "and a fan's wait chooses which", "x") }
    assert_includes moved.message, "the anchor moved; re-cut the row"
    moved = assert_raises(ArgumentError) { Rows.recut(shipped, "A model result you hand on carries the start of its prompt.", "x") }
    assert_includes moved.message, "the anchor moved; re-cut the row", "a screened-out variant's sentence anchors nothing"
    assert_equal "no row R-WO", assert_raises(ArgumentError) { Rows.find("R-WO") }.message
    assert_equal "no row R-EX", assert_raises(ArgumentError) { Rows.find("R-EX") }.message,
      "the records' R-EX names other bytes, so it never resolves to the shipped text"
    assert_raises(ArgumentError) { Rows.find("R-WO+N+B") }
    assert_raises(ArgumentError) { Rows.find("R-PRE") }
  end

  # THE SHIPPED ROW BY NAME: `SHIPPED_ID` is the id this tree's registry text is measured under, and
  # `shipped` finds that row whatever its id, so a definition that must run on any tree — the
  # launcher's rehearsal — reads the text that tree ships. The word is the lookup's, never a row.
  def test_shipped_finds_the_trees_own_shipped_row_whatever_its_id
    assert_equal Rows::SHIPPED_ID, Rows.all.first.id
    assert_equal Rows.all.first, Rows.find("shipped")
    assert_equal Nexus::ToolRegistry.wire_schema_for("compose").fetch("description"), Rows.find("shipped").description
    refute_includes Rows.ids, "shipped"
  end

  # THE RACE READER'S WORDS ARE NO O3 CUE: the race reference's closing lines, where a model reading
  # a race is told each selected tool result names its call, share one stem with O3's stimulus,
  # `read`. This local held-out list names the objective's host-probing and stopping cues; the
  # positive control proves that adding those cues to the reader's lines would be caught.
  def test_the_race_readers_lines_share_only_read_with_o3
    list = ["probe", "host", "first one", "respond*", "stop waiting"]
    stimulus = Objectives.find("O3").text
    shared = E2E::Screen::Stems.intersection(stimulus, Rows::RACE_READER_LINES, list: list)
    assert_equal Set["read"], shared
    assert_empty E2E::Screen::Stems.listed(shared, list: list), "no listed stem"

    cued = E2E::Screen::Stems.intersection(stimulus, "#{Rows::RACE_READER_LINES} Probe each host; stop waiting.", list: list)
    assert_equal Set["probe", "host", "stop waiting"], E2E::Screen::Stems.listed(cued, list: list)
  end

  private

    # A row's examples: its indented blocks, the verb table aside.
    def examples(text)
      text.split("\n\n").select { |block| block.lines.all? { |line| line.start_with?("  ") } }
        .reject { |block| block.start_with?(Rows::VERB_TABLE.lines.first.chomp) }
    end

    # Every model step of a built plan, at any depth of its groups and sequences: a sequence is a
    # list of steps, so flattening the list leaves steps alone.
    def model_steps(steps)
      steps.flatten.flat_map do |step|
        step.key?("parallel") ? model_steps(step.fetch("parallel")) : step.values_at("model").compact
      end
    end

    # Every key a step of a built plan names in `results:`, at any depth.
    def read_keys(steps)
      steps.flatten.flat_map do |step|
        step.key?("parallel") ? read_keys(step.fetch("parallel")) : Array(step.values.sole["results"])
      end
    end

    # The model steps a group briefs alone, at any depth: the first step of each member — a member
    # written as one step is a chain of one — never a step behind another in its member's chain.
    def briefed_alone(steps)
      steps.flatten.flat_map do |step|
        next [] unless step.key?("parallel")

        chains = step.fetch("parallel").map { |member| Array.wrap(member) }
        chains.flat_map { |chain| chain.first.values_at("model").compact } + briefed_alone(chains)
      end
    end
end
