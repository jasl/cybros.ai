module E2E
  module Screen
    # THE ARITHMETIC EVERY SCREEN'S CLAUSES READ. A clause compares two proportions: Wilson's
    # interval per arm and Newcombe's hybrid interval for their difference, the z a parameter
    # (one-sided 90 % unless a clause names another), every bound in POINTS and UNROUNDED — a bound
    # is rounded only where a line prints it, so a rule never decides on a printed digit. A
    # registered figure is an exact binomial sum: the rate a rule fires at when both arms are drawn
    # from given cells of (draws, rate), no simulation noise.
    module Stats
      Z90 = 1.2815515655446004

      Interval = Data.define(:lower, :upper)
      # `diff` is arm − base; `lower`/`upper` its one-sided bounds at the clause's z.
      Contrast = Data.define(:diff, :lower, :upper)

      module_function

      # An arm with no draws knows nothing: the whole unit interval.
      def wilson(k, n, z = Z90)
        return Interval.new(lower: 0.0, upper: 1.0) if n.zero?

        p = k.fdiv(n)
        centre = (p + (z**2) / (2 * n)) / (1 + (z**2) / n)
        half = z * Math.sqrt(p * (1 - p) / n + (z**2) / (4 * n * n)) / (1 + (z**2) / n)
        Interval.new(lower: centre - half, upper: centre + half)
      end

      # (arm − base) with Newcombe's hybrid bounds, in points: the arm is `k1` of `n1`, the base `k2`
      # of `n2`.
      def difference(k1, n1, k2, n2, z = Z90)
        p1 = n1.zero? ? 0.0 : k1.fdiv(n1)
        p2 = n2.zero? ? 0.0 : k2.fdiv(n2)
        one = wilson(k1, n1, z)
        two = wilson(k2, n2, z)
        d = p1 - p2
        Contrast.new(diff: 100 * d,
          lower: 100 * (d - Math.sqrt((p1 - one.lower)**2 + (two.upper - p2)**2)),
          upper: 100 * (d + Math.sqrt((one.upper - p1)**2 + (p2 - two.lower)**2)))
      end

      # One cell's count distribution, index k = P(k of n). Summed in log space, so a large pooled n
      # at a rate near 0 or 1 does not underflow to a distribution of zeros; the two certain rates
      # are exact.
      def binomial(n, p)
        return Array.new(n + 1) { |k| k.zero? ? 1.0 : 0.0 } if p <= 0.0
        return Array.new(n + 1) { |k| k == n ? 1.0 : 0.0 } if p >= 1.0

        whole = Math.lgamma(n + 1).first
        (0..n).map do |k|
          Math.exp(whole - Math.lgamma(k + 1).first - Math.lgamma(n - k + 1).first + k * Math.log(p) + (n - k) * Math.log(1 - p))
        end
      end

      # The pooled count over cells of [draws, rate]: their binomials convolved.
      def pooled(cells) = cells.reduce([1.0]) { |dist, (n, p)| convolve(dist, binomial(n, p)) }

      def convolve(a, b)
        (0...(a.length + b.length - 1)).map do |s|
          a.each_index.sum { |i| (j = s - i).between?(0, b.length - 1) ? a[i] * b[j] : 0.0 }
        end
      end

      # P(the rule fires) with the base drawn from `base` cells and the arm from `arm` cells: the
      # block reads the base's count and draws, then the arm's, and answers whether the rule fires.
      def firing(base, arm)
        one = pooled(base)
        two = pooled(arm)
        one.each_with_index.sum do |pi, i|
          two.each_with_index.sum { |pj, j| yield(i, one.length - 1, j, two.length - 1) ? pi * pj : 0.0 }
        end
      end

      def mean_of(cells) = cells.sum { |n, p| n * p } / cells.sum(&:first)

      def shifted(cells, points) = cells.map { |n, p| [n, (p + points / 100.0).clamp(0.0, 1.0)] }

      # THE CELLS MOVED SO THEIR POOLED MEAN MOVES BY EXACTLY `points`: a margin is a pooled move,
      # and a cell at 0 or 1 cannot follow a uniform shift past its clamp, so the one per-cell shift
      # that lands the pooled mean on its target is solved by bisection over the clamped cells.
      def exact_shift(cells, points)
        target = mean_of(cells) + points / 100.0
        raise ArgumentError, "a pooled move of #{points} points leaves [0, 1]" unless target.between?(0.0, 1.0)

        low = -1.0
        high = 1.0
        100.times do
          middle = (low + high) / 2
          if mean_of(shifted(cells, middle * 100)) > target
            high = middle
          else
            low = middle
          end
        end
        shifted(cells, (low + high) * 50)
      end
    end
  end
end
