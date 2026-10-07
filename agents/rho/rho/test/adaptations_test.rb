require "test_helper"

# RHO'S POLICY OVER THE SDK'S ADAPTATIONS PACK: ONE knob — `auto` applies the pack's row for a model, `off`
# is the kernel's plain declaration, a row id pins that row for every
# model — plus LOCAL rows under `adaptations_dir`, the operator's own
# overrides, which answer before the gem's and are printed `local`. The BOOT row is the universe
# (the pinned row, else the row of `default_model`, else `default`); a
# `--model` whose row differs runs under the boot's spellings and says so.
class AdaptationsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-adaptations")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)
  end

  def teardown = FileUtils.remove_entry(@root)

  def load(settings = {})
    Rho::Adaptations.load(Rho::Config.from_hash(settings), home: @home)
  end

  def test_auto_resolves_the_gem_row_of_a_reference_whatever_lane_serves_it_and_default_otherwise
    resolver = load
    assert_predicate resolver, :auto?
    assert_equal %w[glm-5.3 gem], [resolver.for("openrouter/z-ai/glm-5.3").id, resolver.for("openrouter/z-ai/glm-5.3").source]
    assert_equal "glm-5.3", resolver.for("or/z-ai/glm-5.3").id, "the lane segment is the operator's; the reference is the key"
    assert_equal "claude", resolver.for("anthropic/claude-opus-5-5").id, "a preset row never read on the bench applies under auto"
    assert_equal "codex", resolver.for("codex_subscription/gpt-6.1-sol").id, "both lanes reach the same row"
    assert_equal "default", resolver.for("openrouter/z-ai/glm-5.3-flash").id, "a floor: no gem entry covers it"
    assert_equal "default", resolver.for("dev/mock-text").id
    assert_equal "default", resolver.for(nil).id
    assert_equal "default (gem)", resolver.for("dev/mock-text").label
    assert_equal({ row: "default", source: "gem" }, resolver.facts)
  end

  def test_the_boot_row_is_the_default_models_row_and_another_models_turn_says_so
    resolver = load("default_model" => "openrouter/z-ai/glm-5.3")
    assert_equal "glm-5.3", resolver.boot.id
    refute resolver.boot_differs?("openrouter/z-ai/glm-5.3")
    assert resolver.boot_differs?("openrouter/moonshotai/kimi-k3")
    assert_equal({ row: "kimi-k3", source: "gem", boot_row: "glm-5.3" }, resolver.facts("openrouter/moonshotai/kimi-k3"))
    assert_equal "kimi-k3 (gem; boot row glm-5.3)", Rho::Adaptations.describe(resolver.facts("openrouter/moonshotai/kimi-k3"))
    assert_equal({ row: "glm-5.3", source: "gem" }, resolver.facts, "the default model's own facts carry no boot line")
    assert_equal "glm-5.3", resolver.summarizer.id, "the slot row follows default_model when compaction names no model"
    with_model = load("default_model" => "openrouter/z-ai/glm-5.3",
      "plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "kernel", "model" => "openrouter/moonshotai/kimi-k3" } } })
    assert_equal "kimi-k3", with_model.summarizer.id, "the slot row is the summary model's"
  end

  def test_off_is_the_kernels_plain_declaration_for_every_model
    resolver = load("adaptations" => "off", "default_model" => "openrouter/z-ai/glm-5.3")
    assert_predicate resolver, :off?
    choice = resolver.for("openrouter/z-ai/glm-5.3")
    assert_predicate choice, :off?
    assert_equal %w[off off off], [choice.id, choice.source, choice.label]
    assert_equal "default", choice.row.id, "the set under off is the default row's: the plain names"
    assert_empty choice.hint_texts
    refute resolver.boot_differs?("openrouter/moonshotai/kimi-k3")
    assert_equal({ row: "off", source: "off" }, resolver.facts("openrouter/moonshotai/kimi-k3"))
    assert_equal "off", Rho::Adaptations.describe(resolver.facts)
  end

  def test_a_pinned_row_answers_every_model_and_an_unknown_pin_refuses_the_boot_by_name
    resolver = load("adaptations" => "claude", "default_model" => "openrouter/z-ai/glm-5.3")
    assert_predicate resolver, :pinned?
    assert_equal "claude", resolver.for("openrouter/z-ai/glm-5.3").id
    assert_equal "claude", resolver.boot.id
    refute resolver.boot_differs?("openrouter/moonshotai/kimi-k3"), "a pin is the universe and the turn row alike"

    error = assert_raises(Rho::ConfigurationError) { load("adaptations" => "opencode") }
    assert_match(/adaptations names no row "opencode"; the rows: /, error.message)
    assert_includes error.message, "default"
    assert_includes error.message, @home.adaptations_path
  end

  # THE LOCAL ROWS: `<home>/adaptations/*.yml` by default, or the settings'
  # `adaptations_dir`; a local row answers before the gem's rows and
  # replaces a gem row of the same id; a malformed one refuses the boot
  # naming its file and path.
  def test_local_rows_beat_the_gems_and_a_malformed_one_refuses_the_boot
    RhoTest::LocalRows.write(@home.adaptations_path, "mock", models: ["mock-text"], tool_style: %w[claude codex],
      lead_hints: [{ "id" => "k6", "text" => "Do not wait for a detached call." }])
    resolver = load("default_model" => "dev/mock-text")
    choice = resolver.for("dev/mock-text")
    assert_equal %w[mock local], [choice.id, choice.source]
    assert_equal "mock (local)", choice.label
    assert_equal "mock (local #{File.join(@home.adaptations_path, "mock.yml")})", choice.long_label
    assert_equal ["Do not wait for a detached call."], choice.hint_texts
    assert_equal "mock", resolver.boot.id

    elsewhere = File.join(@root, "rows")
    RhoTest::LocalRows.write(elsewhere, "glm-5.3", models: ["z-ai/glm-5.3"], tool_style: ["codex"])
    moved = load("adaptations_dir" => elsewhere)
    assert_equal %w[glm-5.3 local], [moved.for("openrouter/z-ai/glm-5.3").id, moved.for("openrouter/z-ai/glm-5.3").source],
      "a local row of a gem row's id replaces it"
    assert_equal ["codex"], moved.for("openrouter/z-ai/glm-5.3").row.tool_style
    assert_equal "default", moved.for("dev/mock-text").id, "the home's own directory is not read when another is named"

    File.write(File.join(elsewhere, "broken.yml"), "format: 1\nrow: broken\nmodels: [x]\ntool_style: [gemini]\n")
    error = assert_raises(Rho::ConfigurationError) { load("adaptations_dir" => elsewhere) }
    assert_match(%r{adaptations: .*broken\.yml: tool_style: "gemini" is not one of}, error.message)
  end

  # A LOCAL ROW'S MODELS ARE PATTERNS: `mock-*` covers every mock model,
  # a local exact entry carves one out of it, and the gem's rows keep the
  # references no local entry covers.
  def test_a_local_pattern_row_covers_its_models_and_the_most_specific_entry_answers
    RhoTest::LocalRows.write(@home.adaptations_path, "mocks", models: ["mock-*"], tool_style: ["codex"])
    resolver = load
    assert_equal ["mocks (local)", "mocks (local)"], %w[dev/mock-text dev/mock-priced].map { |model| resolver.for(model).label }
    assert_equal "claude (gem)", resolver.for("anthropic/claude-opus-5-5").label
    assert_equal "default (gem)", resolver.for("openrouter/z-ai/glm-5.3-flash").label

    # `text.yml` sorts after `mocks.yml`, so a first-listed rule would answer `mocks`.
    RhoTest::LocalRows.write(@home.adaptations_path, "text", models: ["mock-text"])
    carved = load
    assert_equal "text (local)", carved.for("dev/mock-text").label, "the exact entry outranks the prefix"
    assert_equal "mocks (local)", carved.for("dev/mock-priced").label
  end

  # THE DECLARATION: the boot row's universe over the kernel's definitions,
  # a recut rendered against the SERVED template; no template served for
  # a recut entry, or a moved anchor, is `AnchorMoved` naming the entry.
  def test_kernel_configuration_renders_recuts_and_refuses_a_moved_anchor
    names = NexusDoubles::KERNEL_CATALOG.map { |row| row.fetch("canonical_name") }
    resolver = load("adaptations" => "claude")
    anchor = resolver.pack.presets.preset("claude").aliases.first.dig("recut", "anchor")
    configuration = resolver.kernel_configuration(names: names, templates: { "nexus.graph.delegate_task" => "The task verb.\n\n#{anchor}\n" })
    assert_empty configuration.fetch(:kernel_tools)
    entries = configuration.fetch(:kernel_aliases)
    assert_equal %w[Agent], entries.map { |entry| entry.dig("function", "name") }, "plain task withheld, the alias added"
    assert_includes entries.last.fetch("description"), "`run_in_background: false` means your next round WAITS"
    refute_includes entries.last.fetch("description"), anchor

    error = assert_raises(CybrosAgent::ModelAdaptations::AnchorMoved) { resolver.kernel_configuration(names: names, templates: {}) }
    assert_match(/Agent: no template served/, error.message)
    error = assert_raises(CybrosAgent::ModelAdaptations::AnchorMoved) do
      resolver.kernel_configuration(names: names, templates: { "nexus.graph.delegate_task" => "The task verb, re-cut." })
    end
    assert_match(/Agent: the anchor moved; re-cut the entry/, error.message)
    assert_equal({ kernel_tools: names, kernel_aliases: [] }, load.kernel_configuration(names: names),
      "the default row is the plain source set, no schema copying or template needed")
  end

  # THE KNOB'S GRAMMAR (Config): auto, off, or a row id; anything else is
  # refused by the key's name; `RHO_ADAPTATIONS` spells it, `adaptations_dir`
  # has no environment spelling and expands `~`.
  def test_the_config_knob_and_the_directory
    assert_equal "auto", Rho::Config.from_hash({}).adaptations
    assert_nil Rho::Config.from_hash({}).adaptations_dir
    assert_equal "off", Rho::Config.from_hash({ "adaptations" => " off " }).adaptations
    assert_equal "glm-5.3", Rho::Config.from_hash({ "adaptations" => "glm-5.3" }).adaptations
    assert_equal File.expand_path("~/rows"), Rho::Config.from_hash({ "adaptations_dir" => "~/rows" }).adaptations_dir
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash({ "adaptations" => "a row" }) }
    assert_equal 'adaptations must be auto, off or a row id, got "a row"', error.message
    assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash({ "adaptations" => "" }) }
    assert_equal "RHO_ADAPTATIONS", Rho::Config::ENV_KEYS.fetch("adaptations")
    refute Rho::Config::ENV_KEYS.key?("adaptations_dir")
    %w[tool_style tool_styles_by_model].each do |gone|
      refute Rho::Config::KEYS.include?(gone), "#{gone} left with the pack (one door: adaptations + local rows)"
    end
    refute Rho::Config::ENV_KEYS.value?("RHO_TOOL_STYLE")
  end
end
