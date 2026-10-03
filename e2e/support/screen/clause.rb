require_relative "stats"

module E2E
  module Screen
    # ONE REGISTERED CLAUSE, READ: the arm's count against the base's over the same cells, their
    # difference (arm − base) with Newcombe's bounds at the clause's z, the rule in its registered
    # words, and whether the rule's condition is met. A harm clause's rule says when it fires, so
    # "HOLDS" there reads "fires"; a screen's verdict reads each clause by its name. A clause over
    # no draws is not decided, whatever its rule would say.
    Clause = Data.define(:name, :arm, :against, :k1, :n1, :k2, :n2, :z, :contrast, :rule, :holds) do
      # The clause over two draw lists: `test` counts a draw, the block answers the rule over the
      # counted clause (its contrast, or its counts for a count rule).
      def self.contrast(name:, arm:, against:, arm_draws:, base_draws:, test:, rule:, z: Stats::Z90)
        k1 = arm_draws.count(&test)
        k2 = base_draws.count(&test)
        counted = new(name: name, arm: arm, against: against, k1: k1, n1: arm_draws.length, k2: k2, n2: base_draws.length, z: z,
          contrast: Stats.difference(k1, arm_draws.length, k2, base_draws.length, z), rule: rule, holds: false)
        counted.with(holds: counted.decided? && yield(counted) == true)
      end

      def decided? = n1.positive? && n2.positive?

      def verdict
        if !decided? then "NOT DECIDED (no draws)"
        elsif holds then "HOLDS"
        else "does not hold"
        end
      end

      def line
        "#{name} #{arm}: #{share(k1, n1)} against #{against} #{share(k2, n2)}; Δ #{points(contrast.diff)} pts, " \
          "lower #{points(contrast.lower)}, upper #{points(contrast.upper)} at z #{z.round(4)} (#{rule}) → **#{verdict}**"
      end

      private

        def share(k, n) = n.zero? ? "0/0" : "#{k}/#{n} (#{(100.0 * k / n).round(1)} %)"

        def points(value) = format("%+.1f", value)
    end
  end
end
