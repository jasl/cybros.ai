require_relative "stats"

module E2E
  module Screen
    # ONE REGISTERED FIGURE: the rate a clause's rule passes, computed exactly over cells of [draws,
    # base rate] — the registered cell sizes at the base's own rates — under a zero-effect change
    # and under a change of `shift` points (the pooled mean moved by exactly that, `Stats.exact_shift`).
    # Each prints beside the same figure for ONE pooled rate of the same mean: stratified cells carry
    # less binomial variance than one rate while Newcombe's bounds are sized from the pooled rate, so
    # the stratified figure passes a zero-effect change more often and an at-margin one less often
    # than the single-rate figure a design quotes.
    Figure = Data.define(:key, :name, :n, :base, :shift, :zero, :at, :single_zero, :single_at) do
      # The block answers whether the rule passes on one contrast (arm − base).
      def self.of(key:, name:, cells:, shift:, z: Stats::Z90, &passes)
        between(key: key, name: name, cells: cells, moved: Stats.exact_shift(cells, shift), shift: shift) do |i, n, j, m|
          passes.call(Stats.difference(j, m, i, n, z))
        end
      end

      # A change no uniform shift spells — a block of cells moving apart, a rate read against a base of
      # none, a count rule: the arm drawn from `moved` against the base drawn from `against` (the base
      # cells unless named). The block reads the base's count and draws, then the arm's, and answers
      # whether the rule passes.
      def self.between(key:, name:, cells:, moved:, shift:, against: cells, &passes)
        single = ->(pool) { [[pool.sum(&:first), Stats.mean_of(pool)]] }
        new(key: key, name: name, n: cells.sum(&:first), base: Stats.mean_of(cells), shift: shift,
          zero: Stats.firing(cells, cells, &passes), at: Stats.firing(against, moved, &passes),
          single_zero: Stats.firing(single.call(cells), single.call(cells), &passes),
          single_at: Stats.firing(single.call(against), single.call(moved), &passes))
      end

      def line
        "#{name}: n = #{n} per arm, base #{percent(base)}: a zero-effect change passes #{percent(zero)}, a change of " \
          "#{format("%+.1f", shift)} points #{percent(at)} — one pooled rate of the same mean: #{percent(single_zero)} and #{percent(single_at)}"
      end

      def stamp
        "sim.#{key}=n #{n}, base #{percent(base)}, zero-effect #{percent(zero)}, at #{format("%+.1f", shift)} #{percent(at)}; " \
          "single rate #{percent(single_zero)} / #{percent(single_at)}"
      end

      private

        def percent(rate) = "#{(100 * rate).round(1)} %"
    end

    # A DRY RUN'S ANSWER: every clause's mechanics run over a pair (printed, never deciding), a kernel
    # finding the pair shows, the registered figures at the registered n, and the stops the screen's
    # rules raise on those figures — a launch with any stop goes no further.
    Figures = Data.define(:clauses, :finding, :figures, :stops) do
      def stop? = stops.any?

      def lines
        [*clauses.map { |clause| "dry: #{clause.line}" }, *finding.map { |evidence| "dry: kernel finding: #{evidence}" },
         *figures.map(&:line), *stops.map { |stop| "STOP: #{stop}" }]
      end

      def stamp_lines = [*figures.map(&:stamp), "sim.stops=#{stops.empty? ? "none" : stops.join("; ")}"]
    end
  end
end
