$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/screen/cells"

# THE PER-CELL COUNTS A READOUT PROMOTES: one row per (arm, instrument, model, objective), counts and
# summed spend only — a script's bytes never leave the records — for the compose bench's records (the
# generated pair) and the task probe's (its draws are its messages).
class ScreenCellsHarnessTest < Minitest::Test
  C = E2E::Screen::Cells
  R = E2E::Screen::Records
  PAIR = File.expand_path("../support/fixtures/screen/pairs/compose-reads", __dir__)

  def test_a_compose_cell_counts_its_draws_and_never_carries_a_script
    draws = R.pair(PAIR)
    cells = C.extract(draws)
    assert_equal 12, cells.length, "two arms × two models × three objectives"
    assert cells.all? { |cell| cell["draws"] == 3 && cell["instrument"] == "compose" }
    text = JSON.generate(cells)
    refute_includes text, "\"script\""
    draws.each { |draw| refute_includes text, JSON.generate(draw.fetch("script").strip[0, 40])[1..-2], "a script's bytes stay in the records" }
    assert_equal cells.map { |cell| cell.values_at(*C::KEY) }.sort_by { |key| key.join }, cells.map { |cell| cell.values_at(*C::KEY) }
  end

  # The counts are the records' own facts: `right` is first-time-right on a plan that could be read,
  # the repair is a call, and every call's tokens are summed.
  def test_a_compose_cells_counts_are_the_records_facts
    draws = R.pair(PAIR)
    cells = C.extract(draws).to_h { |cell| [cell.values_at(*C::KEY), cell] }
    draws.group_by { |draw| draw.values_at(*C::KEY) }.each do |key, cell|
      counted = cells.fetch(key)
      assert_equal cell.count { |draw| draw["first_time_right"] == true && draw["opaque"] != true }, counted["right"], key.join(" ")
      rehearsed = ->(draw) { draw.fetch("rehearsed", {}).values_at("first_time_right", "dropped_value_on_race_member") == [true, 0] }
      assert_equal cell.count { |draw| draw["valid_first"] == true && rehearsed.call(draw) }, counted["rehearsed_right"]
      assert_equal cell.count { |draw| draw["valid_first"] == true }, counted["valid_first"]
      assert_equal cell.count { |draw| draw["usable"] == true }, counted["usable"]
      assert_equal cell.count { |draw| draw["opaque"] == true }, counted["opaque"]
      assert_equal cell.length + cell.count { |draw| draw.key?("repaired") }, counted["calls"]
      assert_equal 5_000 * counted["calls"], counted["input_tokens"]
      assert_in_delta 0.004 * counted["calls"], counted["cost"], 1e-9
    end
    refused = cells.fetch(%w[without compose fake/chat-b O3])
    assert_equal [2, 4, 0, 0], refused.values_at("valid_first", "calls", "lost", "no_call"), "the refused draw's repair is its fourth call"
  end

  # RIGHT″, the rehearsed reading a screen decides on: a valid first script whose plan is right in
  # every world it was rehearsed in, uncredited, and drops no closing value on a race member. A
  # draw with no rehearsal — a refused script has none — is not right″.
  def test_rehearsed_right_is_a_valid_plan_right_in_every_world_that_drops_no_race_members_value
    right = C::COUNTS.fetch("compose").fetch("rehearsed_right")
    draw = { "valid_first" => true, "first_time_right" => false, "opaque" => true,
             "rehearsed" => { "first_time_right" => true, "dropped_value_on_race_member" => 0 } }
    assert right.call(draw), "the rehearsed reading decides, whatever the static one says"
    refute right.call(draw.merge("valid_first" => false))
    refute right.call(draw.merge("rehearsed" => draw.fetch("rehearsed").merge("first_time_right" => false)))
    refute right.call(draw.merge("rehearsed" => draw.fetch("rehearsed").merge("dropped_value_on_race_member" => 1)))
    refute right.call(draw.except("rehearsed"))
  end

  # A task draw's calls are its messages; it is lost when any of them failed. Its door is its scored
  # message's kind: acceptable as the door objective scored it (the widths are the task bench's), a
  # compose whose model leaves go unread is flat, and a compose the builder built is built.
  def test_a_task_cell_counts_its_messages_and_its_doors
    message = ->(index, input) { { "index" => index, "usage" => { "input_tokens" => input, "output_tokens" => 50, "cache_read_tokens" => 800 }, "seconds" => 2.5 } }
    draws = [
      { "right_door" => true, "pass" => true, "messages" => [message.(1, 1_000), message.(2, 1_400)], "scout_then_door" => true,
        "door_kind" => "compose_steps", "built" => true, "members" => 12 },
      { "right_door" => false, "pass" => false, "scout" => true, "messages" => [message.(1, 1_000), message.(2, 1_300), message.(3, 1_600)] },
      { "right_door" => false, "pass" => false, "messages" => [message.(1, 1_000)], "error" => "SimpleInference::TimeoutError: execution expired" },
      { "right_door" => false, "pass" => false, "messages" => [message.(1, 1_000)], "door_kind" => "task_fan", "members" => 6,
        "acceptable_door" => true },
      { "right_door" => false, "pass" => false, "messages" => [message.(1, 1_000)], "door_kind" => "compose_flat", "built" => true, "members" => 0 },
    ].each_with_index.map do |draw, index|
      draw.merge("arm" => "with", "instrument" => "task", "model" => "fake/chat-a", "objective" => "D1P", "sample" => index + 1)
    end
    cells = C.extract(draws)
    assert_equal 1, cells.length
    cell = cells.first
    assert_equal({ "draws" => 5, "lost" => 1, "no_call" => 0, "pass" => 1, "right_door" => 1, "scout" => 1, "scout_then_door" => 1,
                   "acceptable_door" => 1, "compose_flat" => 1, "built" => 2,
                   "calls" => 8, "retries" => 0, "input_tokens" => 9_300, "output_tokens" => 400, "cache_read_tokens" => 6_400,
                   "cache_creation_tokens" => 0, "cost" => 0.0, "seconds" => 20.0 },
      cell.except(*C::KEY))
    acceptable = C::COUNTS.fetch("task").fetch("acceptable_door")
    refute acceptable.call(draws[3].except("acceptable_door")), "a draw the objective never called acceptable is not"
  end
end
