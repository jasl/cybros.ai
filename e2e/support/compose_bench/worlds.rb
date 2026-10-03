require "fileutils"
require "json"
require "tmpdir"
require_relative "../../../nexus/app/services/agent_loops/graph"
require_relative "shape"
require_relative "world_calls"

module E2E
  module ComposeBench
    # THE REHEARSAL'S WORLDS: what every call a plan places answers, per objective, so a stage that
    # reads results can be run the way the kernel runs it. Each value comes from a source that predates
    # the data: the harness's tool contract (`Tools`, all the model saw of the tools), the compose
    # text's envelope words (`Nexus::ToolRegistry::Graph`: status, is_error, output, content,
    # structured_content, error; a race's slot and its `selected`), and the objective's eval environment
    # (`e2e/evals/tasks/compose-<slug>/environment`) — its files read, its `bin/*` stand-ins run. Where
    # those sources are silent the world is a DIMENSION with two admissible spellings: the plainest
    # first (W0, whose graph the record shows) and rho's runner's second, cited only as the reason the
    # spelling is admissible. A draw is rehearsed in W0 first; its other worlds are every combination
    # of the dimensions W0's calls reached, and its verdict counts only where every world agrees.
    module Worlds
      TASKS = File.expand_path("../../evals/tasks", __dir__)
      # The six places the sources are silent, frozen before any batch is read against them:
      #   no_match         — a grep that finds nothing: "" | rho's "No matches found in <path>"
      #   matched_path     — the file a grep line names: as passed | rho's basename for a single file
      #   runner_detail    — rho's detail in an envelope: absent | a non-zero exit's "Command exited
      #                      with code N" with is_error and {"exit_status"}, an edit's replacements
      #   record_format    — O7's model text: a sentence | the three records as a JSON array
      #   compound_command — a stand-in followed by a shell operator: refused | its head alone
      #   model_effect     — an editing model on O2 or O4: changes nothing | does the task on the files
      DIMENSIONS = %w[no_match matched_path runner_detail record_format compound_command model_effect].freeze
      # A world variant is the dimensions spelled the second way; W0 spells none.
      W0 = [].freeze
      # THE HARNESS'S OWN WALL on the stages one draw runs: a rehearsal resource bound like the
      # evaluator's timeout, never a kernel word. A stage past it is cut — never run — and every step
      # downstream of a cut stage is drawn waiting, as the kernel would not have reached it either.
      WALL = 32

      # One objective's world: its environment, the text every model step answers (`text`; O7's
      # other spelling of it in `records`), and what an editing model does to the files under
      # `model_effect` — each path's passages replaced once, in order.
      World = Data.define(:id, :environment, :text, :records, :effects) do
        def self.of(id, slug, text, records: nil, effects: {})
          new(id: id, environment: File.join(TASKS, "compose-#{slug}", "environment"), text: text, records: records, effects: effects)
        end
      end

      # O7's three records as `bin/fetch` serves them, spelled as the JSON array a script parsing a
      # model's text would read.
      RECORDS = JSON.generate([
        { "source" => "a", "date" => "2026-09-01", "id" => "q7f3k" },
        { "source" => "b", "date" => "2026-09-02", "id" => "m2z9p" },
        { "source" => "c", "date" => "2026-09-03", "id" => "x5c1r" },
      ]).freeze

      ALL = [
        World.of("O1", "review-angles", "Reviewed patch.diff: no finding blocks it."),
        World.of("O2", "grep-then-edit", "app/models/team.rb defines full_name at line 5; rename it to display_name.",
          effects: { "app/models/team.rb" => [["def full_name =", "def display_name ="], ["def to_s = full_name", "def to_s = display_name"]] }),
        World.of("O3", "race", "bravo responded first."),
        World.of("O4", "background-suite", "Fixed both offences in app/models/user.rb.",
          effects: { "app/models/user.rb" => [["def active? \n", "def active?\n"], ["enabled == true", "enabled"]] }),
        World.of("O5", "single-read", "app.yml sets the log level to warn."),
        World.of("O7", "three-stage-pairing", "Normalised the source into our record format.", records: RECORDS),
        World.of("O7b", "two-source-fan-in", "Summarised the test, lint and type-check output."),
        World.of("T5", "rendezvous", "Reviewed the migrate, seed and schema dump output."),
      ].freeze

      module_function

      def for(objective) = ALL.find { |world| world.id == objective.id } || raise(ArgumentError, "no world for #{objective.id}")

      # THE RACE'S CLOCK: how long a stand-in of `environment` sleeps for `arguments`, read off the
      # `sleep` it calls when run over a copy of the environment — once per process, since it is a
      # property of the stand-in and its arguments alone.
      def slept(environment, script, arguments)
        @slept ||= {}
        @slept[[environment, script, arguments]] ||= Dir.mktmpdir("clock") do |root|
          files = File.join(root, "files")
          sleeps = File.join(root, "sleeps")
          FileUtils.cp_r(environment, files)
          Calls.execute(files, script, arguments, sleeps: sleeps) if File.file?(File.join(files, script))
          File.exist?(sleeps) ? File.read(sleeps).split.sum(&:to_f) : 0
        end
      end

      # Every world but W0 over the dimensions a draw's W0 run reached: 2^k − 1 of them.
      def variants(touched)
        dimensions = DIMENSIONS & touched
        (1..dimensions.length).flat_map { |size| dimensions.combination(size).map(&:sort) }
      end

      # One result as a reader receives it: the keys of the kernel's `TaskResultProjection.call`, a
      # text answer's `content` the one text block its entries project.
      def envelope(status:, output: nil, is_error: false, structured: nil, error: nil)
        { "status" => status, "is_error" => is_error, "output" => output,
          "content" => output.nil? ? nil : [{ "type" => "text", "text" => output }],
          "structured_content" => structured, "error" => error }
      end

      # The outermost race steps of one scope: a `parallel` with an `until` that is not "all" (`Shape`'s
      # lowering places a join for exactly these), found through sequences and groups but not inside
      # another race — a race in an arm is timed with the race it runs in.
      def races(steps)
        Array(steps).flat_map do |step|
          sequence = Array.try_convert(step)
          if sequence
            races(sequence)
          elsif step.key?("parallel")
            step["until"].nil? || step["until"] == "all" ? races(step["parallel"]) : [step]
          else
            []
          end
        end
      end

      # A race as ranked: its join's mode and count (`Tasks::Compile#place_join`: "any", or a quorum of
      # `until`); its exits — what the join waits on, one source for each exit of every member, as the
      # kernel's join counts them — with the time each ends; their order by that time, ties in written
      # order; and the exits ranked to win.
      Race = Data.define(:key, :mode, :quorum, :exits, :ends, :order, :winners)

      # ONE REHEARSAL'S STATE, stamped as the plan is walked: a copy of the environment the calls
      # change, and what each placed step answered. A mutable in-process handle; nothing of it
      # crosses a boundary but what `Rehearsal` reads off it.
      Run = Struct.new(:world, :variant, :tool_names, :root, :excluded, :envelopes, :verbs, :stages, :returned, :readers,
        :tails, :races, :canceled, :touched, :unknown, :edited, :runs, keyword_init: true) do
        include Calls

        # A run over a fresh copy of `world`'s environment, removed when the block returns. `excluded`
        # names, per race, the exits an earlier rehearsal found failing (`failed_winners`).
        def self.open(world:, variant:, tool_names:, excluded: {})
          Dir.mktmpdir("rehearsal") do |root|
            FileUtils.cp_r(world.environment, File.join(root, "files"))
            yield new(world: world, variant: variant, tool_names: Shape.branch_names(tool_names), root: root, excluded: excluded,
              envelopes: {}, verbs: {}, stages: {}, returned: {}, readers: {}, tails: {}, races: {}, canceled: [],
              touched: [], unknown: [], edited: [], runs: 0)
          end
        end

        # A SCOPE'S RACES, ranked before any of its steps is placed, each with the races in its arms
        # (`rank`). `steps` are the scope's own, keyed and referring as they will be placed.
        def raced(steps)
          Worlds.races(steps).each { |race| rank(race) }
        end

        # A leaf placed in written order — a valid execution order, since the builder refuses a step
        # named before it is placed — settles now: canceled if a race abandoned it, else answered.
        def placed(verb, body)
          key = body.fetch("key")
          verbs[key] = verb
          envelopes[key] = canceled.include?(key) ? loser : answer(verb, body)
        end

        # Whether a stage runs: never one a race canceled, and none past the wall; each run counts.
        def start(key)
          verbs[key] = "script"
          if canceled.include?(key)
            settle(key, "canceled", loser)
          elsif runs >= WALL
            settle(key, "cut", Worlds.envelope(status: "waiting"))
          else
            self.runs += 1
            true
          end
        end

        # What a stage's `results:` hand it, in order: a leaf's envelope, a race's slot; a stage that
        # expanded is read at its expansion's final leaf, as the kernel's splice re-points its readers.
        def results(stage, keys)
          resolved = keys.map { |key| tails.fetch(key, key) }
          readers[stage] = resolved
          resolved.map { |key| races.key?(key) ? slot(key) : envelopes.fetch(key) }
        end

        def failed(key, code, detail)
          settle(key, "failed #{code}", Worlds.envelope(status: "failed", error: { "key" => code.to_s, "detail" => detail }))
        end

        # A value stage's envelope: the value's canonical text, the value itself as the structured
        # content (`Scripts::Run#complete_value`).
        def value(key, value, text)
          returned[key] = value
          settle(key, "value", Worlds.envelope(status: "completed", output: text, structured: value))
        end

        def expanded(key, tail)
          tails[key] = tail
          stages[key] = "expanded"
        end

        def envelope(key) = envelopes.fetch(tails.fetch(key, key))

        # A step's task status on the plan: a join's from what its race selected, every other step's
        # from its envelope.
        def status(key) = races.key?(key) ? join(key).first : envelopes.fetch(key).fetch("status")

        # The stages the wall cut.
        def cut = stages.select { |_, outcome| outcome == "cut" }.keys

        # What the reading records of the dimensions: sorted, once each.
        def dimensions = touched.sort

        # The stages that failed after reading a model's text: a script's parse of prose, most often.
        def model_failures
          stages.count { |key, outcome| outcome == "failed script_error" && readers.fetch(key, []).any? { |read| verbs[read] == "model" } }
        end

        # The exits ranked to win that failed instead, per race: a rehearsal that excludes them hands
        # each race to its next finisher, as the kernel's join waits on until one succeeds.
        def failed_winners
          races.values.to_h { |race| [race.key, race.winners.select { |exit| settlement(exit) == :resolved }] }
            .reject { |_, exits| exits.empty? }
        end

        # A RACE AS ITS JOIN SETTLES IT, over its exits: completed when its first `quorum` finishers
        # succeeded — a completion with `is_error` is a success, a failed exit is absorbed and is not —
        # else failed with the kernel's own word (`Graph.join_failure`) once none is pending, else
        # waiting; canceled, having selected nothing, when an enclosing race outran it. The exits it
        # selected, in finish order, beside.
        def join(key)
          race = races.fetch(key)
          settlements = race.exits.to_h { |exit| [exit, settlement(exit)] }
          won = race.order.select { |exit| settlements[exit] == :success }.first(race.quorum)
          if canceled.include?(key)
            ["canceled", [], nil]
          elsif won.length == race.quorum
            ["completed", won, nil]
          else
            word = AgentLoops::Graph.join_failure(race.mode, (race.quorum unless race.mode == "any"), settlements.values)
            [word ? "failed" : "waiting", won, word]
          end
        end

        # A RACE'S SLOT (`TaskResultProjection.slot`): envelope-shaped — the first envelope it selected,
        # or its own failure — with `selected`, every envelope it hands a reader, first finisher first
        # through every nesting (`TaskResultProjection.tips`) and a failure last; the failure alone
        # when nothing won.
        def slot(key)
          status, _, word = join(key)
          selected = tips(key).map { |tip, _| envelopes.fetch(tip) }
          if status == "completed"
            selected.first.merge("selected" => selected)
          else
            own = Worlds.envelope(status: status, error: word && { "key" => word, "detail" => nil })
            own.merge("selected" => [*selected, own])
          end
        end

        private

          def settle(key, outcome, envelope)
            stages[key] = outcome
            envelopes[key] = envelope
            false
          end

          # Canceled by its race's join (`CancelLosers::REASON`).
          def loser = Worlds.envelope(status: "canceled", error: { "key" => "join_loser_canceled", "detail" => nil })

          # THE RACE CLOCK: a race and the races in its arms timed as the kernel runs them, over the
          # tree's own lowering of the race (`Shape.lower`, whose waits are the kernel's): each step ends
          # its duration (`Calls#duration`, the stand-ins' own sleeps) after the last step it waits on
          # — a sequence adds its steps, a group's members run together, and a step waiting on a step
          # outside the race starts at the race's entry — and a join when its `quorum`-th exit not known
          # to fail ends (with too few left, when its last exit ends). Then each race settled: the
          # first `quorum` of its exits not known to fail win, and every step it waits on, a nested
          # race's join among them, that would end after the last winner is canceled and never runs, as
          # the kernel's `CancelLosers` cancels the join's pending cone. Nothing outside an arm can wait
          # on one of its steps — the builder refuses a reference to a race's member — so no loser is
          # shared work it would spare. With too few exits left to win, nothing is canceled. Residues:
          # a step a stage in the race will place is unknown when the race is ranked, so the stage ranks
          # as instant and what it places is never canceled; and the arms' calls are answered in written
          # order, where the kernel runs them together — only an edit inside an arm could notice.
          def rank(race)
            graph = Shape.lower([race])
            bodies = {}
            Shape.map_leaves([race]) do |verb, body|
              bodies[body.fetch("key")] = [verb, body]
              { verb => body }
            end
            ends = graph.nodes.each_with_object({}) do |node, clock|
              sources = graph.edges.filter_map { |from, to| clock[from] if to == node.key }
              clock[node.key] = node.kind == "join" ? joined(node, graph, clock) : (sources.max || 0) + duration(*bodies.fetch(node.key))
            end
            graph.nodes.each { |node| outran(node.key, graph, ends) if node.kind == "join" }
          end

          # One join ranked over its exits and registered; the time it settles.
          def joined(node, graph, clock)
            exits = graph.edges.filter_map { |from, to| from if to == node.key }
            quorum = node.race == "any" ? 1 : node.race
            order = exits.each_with_index.sort_by { |exit, index| [clock.fetch(exit), index] }.map(&:first)
            winners = (order - excluded.fetch(node.key, [])).first(quorum)
            races[node.key] = Race.new(key: node.key, mode: node.race == "any" ? "any" : "quorum", quorum: quorum, exits: exits,
              ends: exits.to_h { |exit| [exit, clock.fetch(exit)] }, order: order, winners: winners)
            winners.length == quorum ? clock.fetch(winners.last) : exits.map { |exit| clock.fetch(exit) }.max
          end

          # What a settled race cancels: every step it waits on that would end after its last winner.
          def outran(key, graph, ends)
            race = races.fetch(key)
            if race.winners.length == race.quorum
              deadline = race.ends.fetch(race.winners.last)
              losers = cone(key, graph).select { |step| ends.fetch(step) > deadline }
              canceled.concat(losers - canceled)
            end
          end

          # The steps of `graph` a step waits on, directly or through others.
          def cone(key, graph)
            reached = []
            frontier = [key]
            until frontier.empty?
              frontier = graph.edges.filter_map { |from, to| from if frontier.include?(to) && graph.keys.include?(from) } - reached
              reached.concat(frontier)
            end
            reached
          end

          # How an exit settled its race (`Graph.settlement` for a compose step, which the model's
          # compose placed `absorb`): a success when it completed, pending while it waits, skipped when
          # canceled, resolved — absorbed, not a success — when failed. A stage that expanded settles as
          # its expansion's final leaf, where the kernel's splice re-points the join.
          def settlement(exit)
            case status(tails.fetch(exit, exit))
            when "completed" then :success
            when "waiting" then :pending
            when "failed" then :resolved
            else :skip
            end
          end

          # The steps a race hands a reader, each with the time its exit ended: a winner's own step, a
          # nested race's winners in its place — first finisher first, ties in written order.
          def tips(key)
            race = races.fetch(key)
            found = join(key)[1].flat_map do |exit|
              step = tails.fetch(exit, exit)
              races.key?(step) ? tips(step) : [[step, race.ends.fetch(exit)]]
            end
            found.each_with_index.sort_by { |(_, ends), index| [ends, index] }.map(&:first)
          end
      end
    end
  end
end
