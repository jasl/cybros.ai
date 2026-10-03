require_relative "corpus"
require_relative "job"

module E2E
  module Screen
    # THE REPLAY GATE: every tracked corpus script the definition names, replayed in EACH tree — the
    # harness's written-order lowering against that tree's own kernel compile (`ComposeBench::Replay`)
    # — under the order rule the definition registers per tree. One mismatch in either tree stops the
    # launch: a harness that lowers what its kernel refuses (or the other way round) would score the
    # screen against a graph the product never places. Each corpus group is replayed under the tool
    # set its round declared.
    #
    # `replay` is `(scripts, root:, tool_names:, declarations:, ordered:) → result` with `mismatches`
    # and `summary`; `corpus` is `(id) → groups`, each with `scripts`, `tool_names` and
    # `declarations`.
    module ReplayGate
      module_function

      def call(definition:, trees:, replay: default_replay, corpus: Corpus.method(:read))
        spec = definition.stage0.fetch("replay")
        ordered = spec.fetch("ordered")
        trees.flat_map do |tag, root|
          spec.fetch("corpus").map do |id|
            results = corpus.call(id).map do |group|
              replay.call(group.scripts, root: root, tool_names: group.tool_names, declarations: group.declarations,
                ordered: ordered.fetch(tag))
            end
            mismatches = results.sum { |result| result.mismatches.size }
            raise Refused, "the replay found #{mismatches} mismatches in the #{tag} tree over #{id}" if mismatches.positive?

            ["replay.#{tag}.#{id}", results.map(&:summary).join(" | ")]
          end
        end
      end

      # The replay is loaded only when a definition registers this gate.
      def default_replay
        require_relative "../compose_bench/replay"
        ->(scripts, **options) { ComposeBench::Replay.call(scripts, **options) }
      end
      private_class_method :default_replay
    end
  end
end
