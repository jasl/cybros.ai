require "test_helper"

# THE ONE RESOLVER of a turn's compose tier: the flag on `rho do`,
# else the `compose` word when it is `on` or `off`, else — `auto` — the
# model's ADAPTATION ROW's `compose` word (the SDK pack's row, or a local one; none under `adaptations: off`), else on.
# Every rung names its source, which is what `rho do` prints beside the tier.
class ComposeSwitchTest < Minitest::Test
  PACK = CybrosAgent::ModelAdaptations.load

  def row(compose, id: "mock") = PACK.default.with(id: id, source: "local", compose: compose)

  def resolve(flag: nil, row: nil, **settings)
    config = Rho::Config.from_hash(settings.transform_keys(&:to_s))
    Rho::ComposeSwitch.resolve(flag: flag, config: config, row: row)
  end

  def pair(decision) = [decision.on, decision.source]

  def test_no_row_is_on_under_auto
    assert_equal [true, "default"], pair(resolve)
    assert_equal [true, "default"], pair(resolve(row: nil, compose: "auto")), "adaptations off: no rung"
  end

  def test_the_models_row_answers_under_auto_and_names_itself
    assert_equal [false, "row mock"], pair(resolve(row: row("off")))
    assert_equal [true, "row mock"], pair(resolve(row: row("on")))
    assert_equal [true, "row default"], pair(resolve(row: PACK.default)), "the gem's default row says on"
  end

  def test_the_compose_word_beats_the_row
    assert_equal [false, "settings"], pair(resolve(compose: "off", row: row("on")))
    assert_equal [true, "settings"], pair(resolve(compose: "on", row: row("off")))
  end

  def test_the_flag_beats_everything
    assert_equal [true, "flag"], pair(resolve(flag: true, compose: "off", row: row("off")))
    assert_equal [false, "flag"], pair(resolve(flag: false, compose: "on"))
  end

  def test_a_decision_prints_its_word
    assert_equal "on", Rho::ComposeSwitch::Decision.new(on: true, source: "flag").word
    assert_equal "off", Rho::ComposeSwitch::Decision.new(on: false, source: "flag").word
  end

  # THE SUBSET THE INPUT NAMES (mechanism (B)): nil when the whole
  # declaration runs — the tier is on, or the declaration never carried
  # compose — else every declared flat name but `compose`, in declaration
  # order. The switch only narrows: it never adds compose to a declaration
  # that lacks it.
  def test_tool_names_withholds_compose_and_never_adds
    declared = %w[bash compose task ask].map { |name| { "type" => "function", "function" => { "name" => name } } }
    off = Rho::ComposeSwitch::Decision.new(on: false, source: "flag")
    on = Rho::ComposeSwitch::Decision.new(on: true, source: "flag")

    assert_nil Rho::ComposeSwitch.tool_names(declared, on)
    assert_equal %w[bash task ask], Rho::ComposeSwitch.tool_names(declared, off)
    without = declared.reject { |entry| entry.dig("function", "name") == "compose" }
    assert_nil Rho::ComposeSwitch.tool_names(without, off), "a declaration without compose narrows nothing"
  end

  # A task alias remains available when workflow authoring is withheld.
  def test_tool_names_under_compose_off_keeps_an_alias
    declared = %w[bash compose task].map { |name| { "type" => "function", "function" => { "name" => name } } }
    declared << { "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.graph.task" }
    off = Rho::ComposeSwitch::Decision.new(on: false, source: "flag")

    assert_equal %w[bash task Agent], Rho::ComposeSwitch.tool_names(declared, off)
    assert_equal declared.values_at(0, 2, 3), Rho::ComposeSwitch.narrow(declared, %w[bash task Agent])
  end

  def test_compose_off_withholds_every_spelling_of_the_same_kernel_tool
    definitions = %w[bash compose task].map { |name| { "type" => "function", "function" => { "name" => name } } }
    adapted = PACK.default.with(tool_style: %w[nexus workflow],
      tool_descriptions: [{ "name" => "PlanWork", "canonical" => "nexus.graph.compose" }])
    declared = PACK.apply(definitions, adapted)
    off = Rho::ComposeSwitch::Decision.new(on: false, source: "flag")
    on = Rho::ComposeSwitch::Decision.new(on: true, source: "flag")

    assert_equal %w[bash task], Rho::ComposeSwitch.tool_names(declared, off)
    assert_equal definitions.values_at(0, 2),
      Rho::ComposeSwitch.narrow(declared, Rho::ComposeSwitch.tool_names(declared, off))
    assert_nil Rho::ComposeSwitch.tool_names(declared, on)
  end

  def test_narrow_keeps_the_declared_bytes_the_subset_names_in_declaration_order
    declared = %w[bash compose task ask].map { |name| { "type" => "function", "function" => { "name" => name } } }

    assert_equal declared.values_at(0, 2, 3), Rho::ComposeSwitch.narrow(declared, %w[ask bash task])
    assert_equal declared, Rho::ComposeSwitch.narrow(declared, nil)
  end
end
