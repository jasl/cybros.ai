module Conversations
  module Compaction
    # THE PRUNE ARM'S RULE, read by everything that renders a mainline from
    # rows: a round marked `pruned_before: <key>` read every result of
    # the rounds chain-before that key as the kernel's placeholder, and
    # its own sealed body is the prefix later continuations replay — so
    # the composer, the next turn's history and the arm's own bookkeeping
    # must agree on WHICH rounds are cleared. The newest mark wins: a
    # later prune's tail is later.
    module Prune
      module_function

      # How many leading rounds of `rounds` (chain order) compose with
      # their results cleared under `mark` — the newest mark among the
      # rounds unless the caller holds a newer one (the round being
      # composed is not in its own chain). A mark naming a round outside
      # the chain names the composing round itself: everything is cleared.
      def cleared_count(rounds, mark = newest_mark(rounds))
        return 0 if mark.nil?

        rounds.index { |round| round.node_key == mark } || rounds.length
      end

      def newest_mark(rounds)
        rounds.reverse_each do |round|
          mark = round.pruned_before
          return mark if mark
        end
        nil
      end
    end
  end
end
