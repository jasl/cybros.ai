require "test_helper"

# `rho adaptations`'s `models:` line: a row's entries are model PATTERNS, so the line names the
# one that matched the model asked; a row with no entries says how it is reached — `default`
# takes every reference no other row covers, any other empty row only a pin. From the files alone,
# no daemon.
class DevAdaptationsModelsTest < Minitest::Test
  include RhoTest::CliHarness

  def models_line(model: nil)
    reset_out
    Rho::Dev::Conversation.adaptations(cli, [], { model: model })
    @out.string.lines.map(&:chomp).find { |line| line.start_with?("models:") }
  end

  def reset_out = (@out = StringIO.new)

  def settings(document) = File.write(home.settings_path, JSON.generate(document))

  def test_the_models_line_names_the_entry_that_matched
    RhoTest::LocalRows.write(home.adaptations_path, "mocks", models: %w[mock-* mock-text])
    RhoTest::LocalRows.write(home.adaptations_path, "vendor", models: ["fixture/text"])
    assert_equal "models:            mock-*, mock-text (matched mock-text)", models_line(model: "dev/mock-text"),
      "the exact entry outranks the prefix"
    assert_equal "models:            mock-*, mock-text (matched mock-*)", models_line(model: "dev/mock-priced")
    assert_equal "models:            fixture/text (matched fixture/text)", models_line(model: "dev/fixture/text")
  end

  def test_an_empty_row_says_how_it_is_reached
    assert_equal "models:            (every reference no other row covers)", models_line(model: "dev/unknown-x")
    assert_equal "models:            (every reference no other row covers)", models_line, "no model: the default row"

    RhoTest::LocalRows.write(home.adaptations_path, "pinned", tool_style: ["codex"])
    settings("adaptations" => "pinned")
    assert_equal "models:            (none: reached by adaptations: pinned only)", models_line(model: "dev/mock-text")
  end

  def test_a_pinned_row_whose_entries_miss_the_model_names_no_match
    RhoTest::LocalRows.write(home.adaptations_path, "pinned", models: %w[other-a other-b])
    settings("adaptations" => "pinned")
    assert_equal "models:            other-a, other-b", models_line(model: "dev/mock-text")
  end

  def test_a_model_without_its_lane_segment_is_refused_before_a_line_prints
    error = assert_raises(Rho::Error) { models_line(model: "mock-text") }
    assert_equal "model is required, as provider/reference", error.message
    assert_empty @out.string
  end
end
