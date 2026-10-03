module E2E
  module ComposeBench
    # WHAT A SET OF WAIT EDGES IMPLIES. An edge `a → b` says b starts once a settles, so waits
    # compose: `a → b → c` already makes c wait on a, and an `a → c` written beside it restates an
    # implied wait. `reduced` keeps the edges nothing else implies; `closure` holds every pair
    # `[a, c]` the edges make c wait on.
    #
    # A race join (`until: "any"` or a count) settles when enough members do, so the step after it
    # waits on the join and on no member in particular: a path through a race join implies nothing,
    # and an edge into one is never a removal candidate. What reaches a race is a relation of its
    # own — `[x, join]` for each member and every step the member waits on — so a [probe, tag]
    # chain racing where a probe was pictured reads as an extra step, never as a lost wait.
    Waits = Data.define(:reduced, :closure) do
      class << self
        # `joins` are the race joins among the nodes: the lowering places a join only for a race.
        def of(edges, joins:)
          races, plain = edges.uniq.partition { |_, to| joins.include?(to) }
          successors = plain.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
          below = successors.keys.to_h { |key| [key, descendants(key, successors)] }
          waits = below.flat_map { |key, found| found.map { |descendant| [key, descendant] } }
          feeds = races.flat_map do |member, join|
            [member, *below.select { |_, found| found.include?(member) }.keys].map { |source| [source, join] }
          end
          new(reduced: plain.reject { |from, to| implied?(from, to, successors, below) } + races,
              closure: Set.new(waits + feeds))
        end

        private

          def descendants(key, successors)
            found = Set.new
            frontier = successors.fetch(key, [])
            until frontier.empty?
              fresh = frontier.reject { |node| found.include?(node) }
              found.merge(fresh)
              frontier = fresh.flat_map { |node| successors.fetch(node, []) }
            end
            found
          end

          # Another successor of `from` already leads to `to`.
          def implied?(from, to, successors, below)
            successors.fetch(from).any? { |via| via != to && below.fetch(via, Set.new).include?(to) }
          end
      end
    end
  end
end
