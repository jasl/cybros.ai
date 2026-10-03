require "set"

module E2E
  module Evals
    # THE KERNEL CHECK, IN VIVO: what the kernel owes every model step a compose call placed — at its
    # top level or inside a stage it placed — read off a trace, and whether the step's sealed request
    # carried exactly that. A composed step reads only what it names (`Nexus::Compose::Reads`), so
    # its request is the envelopes of its `result_from`, each name read as
    # `TaskResultProjection.referenced` reads one — a race its selection, its own row when it
    # selected nothing — once each and in the order named, then its prompt; it continues nobody's
    # conversation, so no assistant entry is in it; and it has no `input_from`. A step the kernel
    # handed anything else is a KERNEL FINDING, never the model's conduct.
    #
    # An envelope names its tip by the key the model saw: a model result by the root step whose
    # brief it carries — the kernel re-points a name of a model that used tools at its final round,
    # and the envelope walks back to the step — a read across a stage's result boundary by the tip's
    # own key, anything else by its own key. So an owed tip matches an envelope naming it or its root.
    #
    # The reader is pure: the graph's `nodes[].{key, kind, status, expansion_parent, input_from,
    # result_from}`, its edges, each race's settlement off its task row (`result.outcomes`, the
    # snapshot `JoinTask#winning_source_keys` reads), each task row's `completed_at` and the compose
    # calls' keys off the task rows.
    module ComposedReads
      # A race settled in one of these words hands on its partial winners, then itself.
      FAILURES = %w[failed timed_out uncertain].freeze

      Reading = Data.define(:nodes, :outcomes, :calls, :finished) do
        def self.of(graph, tasks)
          new(nodes: Array(graph["nodes"]).to_h { |node| [node["key"], node] },
            outcomes: Array(tasks).to_h { |row| [row["key"], Hash(row.dig("result", "outcomes"))] },
            calls: Array(tasks).select { |row| row["tool_name"] == Trace::COMPOSE }.map { |row| row["key"] },
            finished: Array(tasks).to_h { |row| [row["key"], row["completed_at"].to_s] })
        end

        # EVERY MODEL STEP A COMPOSE CALL PLACED, in graph order: its parent is the call or a stage
        # under it. A member's own rounds hang under the member and are the kernel's continuation of
        # it, which reads its round's calls by design.
        def steps = nodes.values.select { |node| node["kind"] == "model_task" && composed?(node["expansion_parent"]) }

        # What the kernel owes the step, and what it handed it by position.
        def fact(node)
          owed = Array(node["result_from"]).flat_map { |key| referenced(key) }.uniq
          { "owed" => owed, "roots" => owed.map { |key| root(key) }, "positional" => Array(node["input_from"]) }
        end

        private

          # Under a compose call: the call itself, or a stage whose own parent chain reaches one.
          def composed?(key)
            return true if calls.include?(key)

            node = nodes[key]
            !node.nil? && node["kind"] == "script_task" && composed?(node["expansion_parent"])
          end

          def join?(key) = nodes.dig(key, "kind") == "join_task"
          def status(key) = nodes.dig(key, "status")
          def winners(join) = outcomes.fetch(join, {}).select { |_, outcome| outcome == "completed" }.keys

          # WHAT A READER NAMING `key` READS (`TaskResultProjection.referenced`): a leaf itself, a race
          # its selection, or its own row when it selected nothing.
          def referenced(key)
            selection = join?(key) ? in_finish_order(tips(key)) : [key]
            selection.empty? ? [key] : selection
          end

          # The kernel hands a race's selection over in finish order — the first finisher first, a
          # failed race's failure after its winners — never in the order its outcomes were written,
          # which is placement's: by each task row's `completed_at`, then the graph's own order,
          # as the kernel breaks a tie by row.
          def in_finish_order(keys) = keys.sort_by { |key| [finished.fetch(key, ""), nodes.keys.index(key)] }

          # `TaskResultProjection.tips` from one race: a completed race hands on its winners — a nested
          # race among them its own — and a race settled in a failure word its partial winners, then
          # itself; any other race — a person's cancel — nothing.
          def tips(join, seen = Set.new)
            return [] unless seen.add?(join)
            return [] unless status(join) == "completed" || FAILURES.include?(status(join))

            selected = winners(join).flat_map { |key| join?(key) ? tips(key, seen) : [key] }
            status(join) == "completed" ? selected : selected + [join]
          end

          # The step a model tip continues: its round's parent while that is a model round, the key
          # itself for any other tip.
          def root(key)
            parent = nodes.dig(key, "expansion_parent")
            nodes.dig(key, "kind") == "model_task" && nodes.dig(parent, "kind") == "model_task" ? root(parent) : key
          end
      end

      module_function

      # Per composed model step of the trace's graph, what the kernel owes it (`Reading#fact`); nil
      # when no compose call placed a model step.
      def owed(trace)
        reading = Reading.of(trace.graph, trace.tasks)
        steps = reading.steps
        steps.empty? ? nil : steps.to_h { |node| [node["key"], reading.fact(node)] }
      end

      # THE CHECK: true when every composed step whose request was read carried exactly what it is
      # owed — its envelopes naming the owed tips in order, no assistant entry — and none reads by
      # position; else the first finding, in words; nil when no step's request was read.
      def check(owed, requests)
        owed = Hash(owed)
        positional = owed.find { |_, fact| fact.fetch("positional").any? }
        return "#{positional[0]} reads #{positional[1]["positional"].inspect} by position" if positional

        read = Hash(requests).compact.select { |key, _| owed.key?(key) }
        return nil if read.empty?

        read.each do |key, request|
          finding = finding(key, owed.fetch(key), request)
          return finding if finding
        end
        true
      end

      def finding(key, fact, request)
        if request.fetch("assistant").positive?
          "#{key}'s request carries #{request["assistant"]} assistant #{request["assistant"] == 1 ? "entry" : "entries"}"
        elsif !delivered?(fact, request.fetch("tasks"))
          "#{key} was delivered #{request["tasks"].inspect} where it is owed #{fact["owed"].inspect}"
        end
      end

      def delivered?(fact, tasks)
        tasks.length == fact.fetch("owed").length &&
          tasks.each_with_index.all? { |task, index| [fact["owed"][index], fact["roots"][index]].include?(task) }
      end
      private_class_method :finding, :delivered?
    end
  end
end
