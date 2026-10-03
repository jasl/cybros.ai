require "active_support/core_ext/enumerable"
require "mini_racer"
require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "../../../nexus/lib/nexus/compose/reads"
require_relative "../compose_bench/inline"
require_relative "../compose_bench/shape"

module E2E
  module TaskBench
    # THE DOOR A SCORED MESSAGE WENT THROUGH, a kind for every message, read by property from the
    # calls as the kernel resolves them (`Objectives::Call`). A message with a `compose` call is
    # read by its FIRST one: the script built by the shipped evaluator under the round's declared
    # names, refused where the kernel's lowering refuses it (`Shape.lowering_refusal`), its
    # result-free stages inlined (`Shape.inline`, under the names a branch inherits), and what comes
    # back to the caller read by the one rule, `Nexus::Compose::Reads.unread`, over this walk of the
    # inlined plan — a key inside a stage's expansion that is not its final leaf is internal and
    # never comes back. Then, in order:
    #
    # - `compose_refused`: the evaluator or the lowering refused it (`built` false) — a script that
    #   places no step among them, whatever it returns: only a stage may answer with a value;
    # - `compose_one`: one leaf in all;
    # - `compose_opaque`: no model leaf, and a stage that reads results — its shape is in a body no
    #   text can know;
    # - `compose_gather`: no model leaf, a `wait` among the leaves;
    # - `compose_tools`: no model leaf, two leaves or more;
    # - `compose_steps`: some model leaf is READ by a later step, and every model leaf that comes
    #   back names its own `results:` — the readers of a panel or of a chain per item;
    # - `compose_flat`: every other plan with a model leaf — a fan nothing reads, a dangling
    #   summariser, a fan fed its input by `results:` and read by nothing.
    #
    # Without a compose call: `task_fan` (two tasks or more), `task_one`, `spawn`, `start_process`,
    # `none` (no call: the model answered) and `plain`. `scout` is `Sample`'s: three read-only
    # messages chose no door. The FACTS beside the kind, never folded into it: `built`, the script
    # built (none without a compose call); `members`, the model leaves some step reads — a leaf a
    # step's `results:` names, or an exit of a race whose barrier it names, as the lowering reads a
    # race (`Shape.race_reads`) — or the task count; `unread`, the keys that come back; `beside`,
    # the other calls' names in the message.
    class Door < Data.define(:kind, :built, :members, :unread, :beside)
      COMPOSE = "compose".freeze
      START_PROCESS = "start_process".freeze
      SCOUT = "scout".freeze
      STEPS = "compose_steps".freeze
      TASK_FAN = "task_fan".freeze
      TASK_ONE = "task_one".freeze

      class << self
        # `calls` are the message's resolved calls; `declared` the round's function definitions.
        def kind(calls, declared:)
          index = calls.index { |call| call.tool == COMPOSE }
          if index
            composed(calls.fetch(index), declared.map { |entry| entry.dig("function", "name") },
              names(calls.reject.with_index { |_, at| at == index }))
          else
            delegated(calls)
          end
        end

        private

          def composed(call, names, beside)
            arguments = call.arguments || {}
            built = Nexus::Compose::Evaluator.call(script: arguments["script"].to_s, params: arguments["params"] || {}, tool_names: names)
            if built.built? && ComposeBench::Shape.lowering_refusal(built.steps, names).nil?
              planned(ComposeBench::Shape.inline(built.steps, tool_names: names), beside)
            else
              new(kind: "compose_refused", built: false, members: 0, unread: [], beside: beside)
            end
          end

          def planned(inlined, beside)
            walk = Walk.new.place_all(inlined.steps, races: [], internal: false)
            unread = Nexus::Compose::Reads.unread(walk.keys, named: walk.named, members: walk.raced, internal: walk.internal, retired: [])
            models = walk.leaves.select(&:model?)
            read = models.map(&:key) & ComposeBench::Shape.lower(inlined.steps).nodes.flat_map(&:reads)
            flat = models.any? { |leaf| unread.include?(leaf.key) && !leaf.reads? }
            new(kind: plan_kind(walk.leaves, models, inlined, read.any? && !flat), built: true, members: read.size,
              unread: unread, beside: beside)
          end

          def plan_kind(leaves, models, inlined, stepped)
            if leaves.size == 1
              "compose_one"
            elsif models.empty? && inlined.opaque.any?
              "compose_opaque"
            elsif models.empty? && leaves.any? { |leaf| leaf.verb == "wait" }
              "compose_gather"
            elsif models.empty?
              "compose_tools"
            elsif stepped
              STEPS
            else
              "compose_flat"
            end
          end

          # The door's own calls and what stands beside them: the tasks, else a spawn, else a
          # started process; a message of other calls is plain, and one of none answered.
          def delegated(calls)
            tasks = calls.count(&:task?)
            if tasks >= 2
              around(TASK_FAN, calls, tasks, &:task?)
            elsif tasks == 1
              around(TASK_ONE, calls, tasks, &:task?)
            elsif calls.any?(&:spawn?)
              around("spawn", calls, 0, &:spawn?)
            elsif calls.any? { |call| call.tool == START_PROCESS }
              around(START_PROCESS, calls, 0) { |call| call.tool == START_PROCESS }
            else
              around(calls.empty? ? "none" : "plain", calls, 0) { false }
            end
          end

          # A kind whose own calls are those the block picks; `beside` names the rest.
          def around(kind, calls, members, &own) = new(kind: kind, built: nil, members: members, unread: [], beside: names(calls.reject(&own)))

          def names(calls) = calls.map(&:name).uniq
      end

      # The record's facts, under the names a screen reads.
      def fields = { "door_kind" => kind, "built" => built, "members" => members, "unread" => unread, "beside" => beside }

      # One placed leaf: its verb and the keys it reads (`Reads.of`).
      Leaf = Data.define(:key, :verb, :results) do
        def model? = verb == "model"
        def reads? = results.any?
      end

      # THE INLINED PLAN, WALKED: every key in placement order — a leaf where it stands, a race's
      # barrier after its members — the keys each step's `results:` name, the keys placed inside a
      # race, and the keys inside an expansion that are not its final leaf. A stage inside a stage
      # keeps its final leaf internal to the stage around it.
      class Walk
        attr_reader :keys, :named, :raced, :internal, :leaves

        def initialize
          @keys = []
          @named = []
          @raced = []
          @internal = []
          @leaves = []
        end

        def place_all(steps, races:, internal:)
          Array(steps).each { |step| place(step, races: races, internal: internal) }
          self
        end

        private

          def place(step, races:, internal:)
            sequence = Array.try_convert(step)
            if sequence
              place_all(sequence, races: races, internal: internal)
            elsif step.key?("parallel")
              place_group(step, races: races, internal: internal)
            elsif step.key?(ComposeBench::Shape::EXPANSION)
              place_expansion(step.fetch(ComposeBench::Shape::EXPANSION).fetch("steps"), races: races, internal: internal)
            else
              # A leaf is one pair, its verb and its body.
              place_leaf(*step.first, races: races, internal: internal)
            end
          end

          def place_group(step, races:, internal:)
            ends = step["until"]
            race = step.fetch("key") unless ends.nil? || ends == "all"
            inside = race ? races + [race] : races
            Array(step["parallel"]).each { |member| place(member, races: inside, internal: internal) }
            placed(race, races: races, internal: internal) if race
          end

          def place_expansion(steps, races:, internal:)
            place_all(steps, races: races, internal: true)
            @internal.delete(ComposeBench::Shape.exits(steps).sole) unless internal
          end

          def place_leaf(verb, body, races:, internal:)
            key = body.fetch("key")
            results = Nexus::Compose::Reads.of(verb, body["results"])
            placed(key, races: races, internal: internal)
            @named.concat(results)
            @leaves << Leaf.new(key: key, verb: verb, results: results)
          end

          def placed(key, races:, internal:)
            @keys << key
            @raced << key if races.any?
            @internal << key if internal
          end
      end
    end
  end
end
