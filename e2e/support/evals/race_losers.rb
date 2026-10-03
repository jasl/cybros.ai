require "set"

module E2E
  module Evals
    # WHAT A SETTLED RACE LEFT BEHIND, read off a trace: every node of a settled race's structural
    # cone that no winner's own cone holds — the pending arms the kernel's `CancelLosers` stopped,
    # work a winner shares spared. A step settled in the cone after its race had its answer (a
    # refusal that beat the loser cancel's terminalize) is that race's residue. An open race has
    # none.
    #
    # The reader is pure: the graph's `nodes[].{key, kind, status}` and its structural `edges`, and
    # each race's settlement off its task row (`result.outcomes`, the snapshot
    # `JoinTask#winning_source_keys` reads).
    module RaceLosers
      TERMINAL = %w[completed failed canceled timed_out uncertain skipped].freeze

      Reading = Data.define(:nodes, :parents, :outcomes) do
        def self.of(graph, tasks = [])
          structural = Array(graph["edges"]).select { |edge| edge["structural"] }
          new(nodes: Array(graph["nodes"]).to_h { |node| [node["key"], node] },
            parents: structural.group_by { |edge| edge["to"] }.transform_values { |edges| edges.map { |edge| edge["from"] }.uniq },
            outcomes: Array(tasks).to_h { |row| [row["key"], Hash(row.dig("result", "outcomes"))] })
        end

        def losers
          settled.flat_map { |join| cone(join) - winners(join).flat_map { |key| [key, *cone(key)] } }.uniq
        end

        private

          def settled
            nodes.values.select { |node| node["kind"] == "join_task" && TERMINAL.include?(node["status"]) }.map { |node| node["key"] }
          end

          def winners(join) = outcomes.fetch(join, {}).select { |_, outcome| outcome == "completed" }.keys

          # Every structural ancestor of `key`, each once.
          def cone(key, seen = Set.new)
            parents.fetch(key, []).flat_map { |source| seen.add?(source) ? [source, *cone(source, seen)] : [] }
          end
      end

      module_function

      def of(graph, tasks) = Reading.of(graph, tasks).losers
    end
  end
end
