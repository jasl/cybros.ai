$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "support/screen/stats"

# THE ARITHMETIC EVERY SCREEN READS, PINNED ON FIGURES A READOUT ALREADY PRINTED: the T1 text-bench
# readout (`e2e/evals/analysis/2026-09-26-t1/analysis.md`) computed its endpoint, its gates and its
# guard's no-effect rates with Wilson's interval, Newcombe's hybrid difference and exact binomial
# sums; the library reproduces each printed figure. T1 compared a bound AS PRINTED (rounded to 0.1
# point), so the guard's figures here round before they compare; the library's bounds are unrounded.
class ScreenStatsHarnessTest < Minitest::Test
  S = E2E::Screen::Stats
  # T1's guard z: one-sided 90 % family-wise over its seven objectives.
  Z_GUARD = 2.1893

  def test_the_one_sided_90_percent_z_is_the_readouts_constant
    assert_equal 1.2815515655446004, S::Z90
  end

  # T1's endpoint, gates and asides, each as its readout printed it.
  def test_newcombes_difference_reproduces_the_t1_figures
    drop = S.difference(19, 36, 4, 45)
    assert_equal [43.9, 31.2], [drop.diff.round(1), drop.lower.round(1)], "the O3 labels drop R-WO − R-L3"

    gate = S.difference(165, 168, 163, 168)
    assert_equal [1.2, -1.1], [gate.diff.round(1), gate.lower.round(1)], "the floor gate R-L3 − R-WO"

    judged = S.difference(27, 46, 7, 48)
    assert_equal [44.1, 31.9], [judged.diff.round(1), judged.lower.round(1)], "the labels over judged scripts"

    assert_equal(-2.5, S.difference(163, 168, 163, 168).lower.round(1), "the zero-difference bound at 163/168")
    assert_equal(-4.3, S.difference(151, 168, 151, 168).lower.round(1), "the zero-difference bound at 151/168")
  end

  def test_bounds_are_unrounded_points_and_an_empty_arm_reads_the_whole_interval
    contrast = S.difference(19, 36, 4, 45)
    refute_equal contrast.lower.round(1), contrast.lower, "a bound is compared unrounded and rounded only where it prints"
    assert_operator contrast.lower, :<, contrast.diff
    assert_operator contrast.diff, :<, contrast.upper

    assert_equal S::Interval.new(lower: 0.0, upper: 1.0), S.wilson(0, 0)
    empty = S.difference(0, 0, 3, 10)
    assert_in_delta(-30.0, empty.diff, 1e-9)
    assert_operator empty.upper - empty.lower, :>, 100.0, "an arm with no draws carries no information"
  end

  # T1's guard power: one objective, 48 readable draws per arm, the veto when the fall's lower bound
  # at z 2.1893 is above 0.
  def test_firing_reproduces_the_t1_guard_power
    veto = ->(i, n, j, m) { S.difference(i, n, j, m, Z_GUARD).lower.round(1).positive? }
    assert_equal 64.3, (100 * S.firing([[48, 0.5]], [[48, 0.5 - 12.fdiv(48)]], &veto)).round(1)
    assert_equal 66.3, (100 * S.firing([[48, 0.3]], [[48, 0.3 - 10.fdiv(48)]], &veto)).round(1)
  end

  # T1's no-effect veto rates, per objective and family-wise, over the cells its readout listed (each
  # cell's readable draws scaled to the batch's 12 and its right share), both arms drawn from them.
  def test_firing_over_pooled_cells_reproduces_the_t1_guard_no_effect_rates
    veto = ->(i, n, j, m) { S.difference(i, n, j, m, Z_GUARD).lower.round(1).positive? }
    cells = {
      "O2" => [[2, 1.0], [2, 0.0]],
      "O3" => [[6, 1.0], [4, 1.0], [6, 1.0]],
      "O4" => [[12, 2.fdiv(6)], [8, 2.fdiv(4)], [12, 0.0], [10, 2.fdiv(5)]],
      "O7" => [[12, 2.fdiv(6)], [4, 1.fdiv(2)], [4, 1.fdiv(2)], [6, 2.fdiv(3)]],
      "O7b" => [[10, 0.0], [12, 0.0], [10, 4.fdiv(5)], [12, 1.fdiv(6)]],
    }
    rates = cells.transform_values { |rated| S.firing(rated, rated, &veto) }
    assert_equal({ "O2" => 0.0, "O3" => 0.0, "O4" => 0.82, "O7" => 1.47, "O7b" => 0.04 },
      rates.transform_values { |rate| (100 * rate).round(2) })
    family = 1 - rates.values.reduce(1.0) { |product, rate| product * (1 - rate) }
    assert_equal 2.3, (100 * family).round(1)
  end

  def test_a_pooled_distribution_is_a_distribution_even_where_one_binomial_would_underflow
    one = S.pooled([[480, 0.99]])
    assert_in_delta 1.0, one.sum, 1e-9
    assert_equal 481, one.length
    assert_in_delta 475.2, one.each_with_index.sum { |p, k| p * k }, 1e-6
    assert_equal [1.0], S.binomial(12, 1.0).last(1)
    assert_equal 1.0, S.binomial(12, 0.0).first
    assert_in_delta 1.0, S.pooled([[24, 0.3], [24, 0.7], [8, 0.0], [8, 1.0]]).sum, 1e-9
  end

  # THE MARGIN IS A POOLED MOVE: one per-cell shift, solved over the clamped cells, moves the pooled
  # mean by exactly `points` — a cell at 1.0 cannot rise, so the others rise further.
  def test_exact_shift_moves_the_pooled_mean_by_exactly_the_points_with_the_clamp_respected
    cells = [[24, 0.95], [24, 1.0], [24, 0.2], [12, 0.0]]
    [-7.5, -5.0, 5.0, 20.0, 30.0].each do |points|
      moved = S.exact_shift(cells, points)
      assert_in_delta S.mean_of(cells) + points / 100.0, S.mean_of(moved), 1e-9, "a move of #{points} points"
      assert moved.all? { |_n, p| p.between?(0.0, 1.0) }, "every cell stays a probability at #{points} points"
      assert_equal cells.map(&:first), moved.map(&:first), "the cell sizes never move"
    end
    rising = S.exact_shift(cells, 20.0)
    assert_equal 1.0, rising[1][1], "a cell at the ceiling stays there"
    assert_operator rising[2][1] - 0.2, :>, 0.2, "so the cells below it rise more than the pooled 20 points"
    assert_raises(ArgumentError) { S.exact_shift([[10, 0.9]], 20.0) }
  end
end
