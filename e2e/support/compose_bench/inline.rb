require_relative "../../../nexus/lib/nexus/canonical_json"
require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "../../../nexus/lib/nexus/size_bounds"
require_relative "../../../nexus/app/services/agent_loops/scripts/run"
require_relative "shape"

module E2E
  module ComposeBench
    module Shape
      # The kernel's word for a source that does not parse, a compose script's or a stage's, and for
      # nothing else: a SyntaxError the running script raises on data (JSON.parse on a tool's output)
      # is `script_error`.
      SYNTAX_ERROR = "script_syntax_error".freeze

      # A plan with its result-free stages inlined: `steps` for `Shape.lower`, and each stage by
      # what became of it — `inlined` (replaced by its expansion), `refused` (a `StageRefusal`: the
      # kernel fails it whatever the plan produces), `opaque` (it reads results, so its body depends
      # on output no text can know) and `valued` (it returns a value and places nothing). Apart from
      # those, `placers`: the stages whose run over no results built steps the kernel's stage
      # lowering accepts — every inlined stage, and a result-reading stage that places a step
      # before it reads anything — so the static picture never takes one, nor a refused stage, for
      # a value or for a computing step (`Picture#score`). Keys are the plan's, an outer stage before the stages its
      # expansion placed. `tool_names` is the round's set; a stage lowers under the set a branch
      # inherits (`Shape.branch_names`), at any depth.
      Inlined = Data.define(:steps, :inlined, :refused, :opaque, :valued, :placers) do
        # The stages whose source does not parse — the kernel fails them whatever the plan produces
        # — apart from the stages refused for anything else.
        def unparsed = refused.select { |stage| stage.refusal == SYNTAX_ERROR }
      end
      StageRefusal = Data.define(:key, :refusal, :detail)

      def self.inline(steps, tool_names:, world: nil) = Inliner.new(tool_names: tool_names, world: world).call(steps)

      # THE STAGE INLINER: what a result-free `g.script` stage places does not depend on anything
      # the plan produces, so the SHIPPED evaluator can build it now, with `results: []`, exactly
      # as the kernel's stage run will. Each such stage becomes an `expansion` step holding the
      # steps it builds — recursively, and namespaced under the stage's key (`script-1/tool-1`) so
      # they never meet the plan's own keys — and every `after:` or `results:` naming the stage
      # names the expansion's final leaf, as the kernel's splice re-points the stage's readers to
      # the expansion's tail. A stage that reads results, returns a value or is refused stays a
      # stage leaf. The kernel's stage lowering and its step compiler also refuse what the evaluator
      # built — a `g.tool` or a `g.model`'s `tools` naming a tool the stage does not inherit (the
      # graph verbs never are), a key out of format or over its bound, a value the row store cannot
      # hold — and place nothing, so those refusals are read here too (`Shape.lowering_refusal`). A
      # stage that reads results is refused only when its source does not parse, which no result
      # can change.
      #
      # IN A WORLD (`Worlds::Run`, the rehearsal's) every stage runs as the kernel's stage run
      # (`AgentLoops::Scripts::Run#call`) runs it, the same outcomes in the same order, each read with
      # the kernel's own predicate: a stage its race canceled, or past the rehearsal's wall, never runs;
      # one nested deeper than `Scripts::Run::MAX_STAGE_DEPTH` fails `script_depth_exceeded`; its
      # `results:` are the envelopes the world settled, refused `script_input_too_large` past the
      # snapshot bound; then the evaluator over them, and what it built is placed as above — a value
      # the row store cannot hold fails `result_unstorable`, and a refusal other than a parse is a
      # failure at run time, not a stage the kernel refuses whatever the plan produces. Every other step
      # is handed to the world as it is placed, in written order, and every race in a scope before its
      # steps.
      class Inliner
        REFERENCES = %w[after results].freeze

        def initialize(tool_names:, world: nil)
          @stage_names = Shape.branch_names(tool_names)
          @world = world
          @inlined = []
          @refused = []
          @opaque = []
          @valued = []
          @placers = []
        end

        def call(steps)
          Inlined.new(steps: scope(steps, ""), inlined: @inlined, refused: @refused, opaque: @opaque, valued: @valued,
            placers: @placers)
        end

        private

          # One script's steps: its keys under `prefix` — a race's as well as a leaf's, since a
          # reference may name either — each result-free stage expanded, then every reference to
          # an expanded stage re-pointed at that expansion's final leaf. A script names only its
          # own steps, so the re-pointing stays inside the scope.
          def scope(steps, prefix)
            tails = {}
            keyed = Shape.map_leaves(races_renamed(steps, prefix)) { |verb, body| { verb => renamed(body, prefix) } }
            @world&.raced(keyed)
            placed = Shape.map_leaves(keyed) do |verb, named|
              if verb == "script"
                stage(named, tails)
              else
                @world&.placed(verb, named)
                { verb => named }
              end
            end
            Shape.map_leaves(placed) { |verb, body| { verb => pointed(body, tails) } }
          end

          def races_renamed(steps, prefix)
            Array(steps).map do |step|
              sequence = Array.try_convert(step)
              if sequence
                races_renamed(sequence, prefix)
              elsif step.key?("parallel")
                step.merge(step.slice("key").transform_values { |key| prefix + key },
                  "parallel" => races_renamed(step["parallel"], prefix))
              else
                step
              end
            end
          end

          def renamed(body, prefix)
            references = body.slice(*REFERENCES).transform_values { |keys| keys.map { |key| prefix + key } }
            body.merge(references, "key" => prefix + body.fetch("key"))
          end

          def pointed(body, tails)
            body.merge(body.slice(*REFERENCES).transform_values { |keys| keys.map { |key| tails.fetch(key, key) } })
          end

          def stage(body, tails)
            if @world
              rehearse(body, tails)
            elsif Array(body["results"]).empty?
              expand(body, tails)
            else
              read_later(body)
            end
          end

          # The kernel's stage run, in its order (`Scripts::Run#call`), over what the world settled.
          def rehearse(body, tails)
            key = body.fetch("key")
            @opaque << key unless Array(body["results"]).empty?
            if !@world.start(key)
              { "script" => body }
            elsif depth(key) > AgentLoops::Scripts::Run::MAX_STAGE_DEPTH
              refused(body, "script_depth_exceeded", AgentLoops::Scripts::Run::DEPTH_EXCEEDED)
            else
              results = @world.results(key, Array(body["results"]))
              if Nexus::SizeBounds.json_within?(:snapshot_bound, { "params" => body["params"] || {}, "results" => results })
                place(body, evaluate(body, results: results), tails)
              else
                refused(body, "script_input_too_large", nil)
              end
            end
          end

          # How deep a stage is nested, itself counted (`ExpansionOwnership.stage_depth`): a stage's key
          # holds one segment per stage above it, since only a stage's expansion is keyed under it.
          def depth(key) = key.count("/") + 1

          # Evaluated with no results to parse it and to see whether it places steps before it reads
          # anything: the kernel's `script_syntax_error` names a source that does not parse, and any
          # other failure here — a property of an envelope that is not there, JSON.parse on output
          # that is not there — is the empty list's, not the stage's.
          def read_later(body)
            built = evaluate(body)
            if built.refusal.to_s == SYNTAX_ERROR
              @refused << StageRefusal.new(key: body.fetch("key"), refusal: built.refusal.to_s, detail: built.detail.to_s)
            else
              @opaque << body.fetch("key")
              @placers << body.fetch("key") if built.steps? && lowering_refusal(built).nil?
            end
            { "script" => body }
          end

          # The kernel's own stage run over this body: its results, the set a branch inherits.
          def evaluate(body, results: [])
            Nexus::Compose::Evaluator.stage(
              script: body.fetch("script"), params: body["params"] || {}, results: results, tool_names: @stage_names
            )
          end

          # What the kernel's stage lowering refuses of the steps a run built: a stage it refuses
          # fails and places nothing.
          def lowering_refusal(built) = built.steps? ? Shape.lowering_refusal(built.steps, @stage_names, stage: true) : nil

          def expand(body, tails) = place(body, evaluate(body), tails)

          # What a stage run built, placed: a refusal, a value, a refusal of the kernel's lowering, or
          # the expansion that replaces the stage.
          def place(body, built, tails)
            lowering = lowering_refusal(built)
            if !built.built?
              refused(body, built.refusal.to_s, built.detail.to_s)
            elsif built.value?
              valued(body, built.value)
            elsif lowering
              refused(body, lowering.refusal, lowering.detail)
            else
              expanded(body, built, tails)
            end
          end

          # With no world, every refusal is the stage's own. In a world only a source that does not parse
          # is — the kernel refuses it whatever the results — and every refusal is the stage's failure.
          def refused(body, refusal, detail)
            key = body.fetch("key")
            @refused << StageRefusal.new(key: key, refusal: refusal, detail: detail) if @world.nil? || refusal == SYNTAX_ERROR
            @world&.failed(key, refusal, detail)
            { "script" => body }
          end

          # A value the row store cannot hold fails the stage, as the kernel's `complete_value` does
          # when its encoding raises.
          def valued(body, value)
            key = body.fetch("key")
            @world.value(key, value, Nexus::CanonicalJson.encode(value)) if @world
            @valued << key
            { "script" => body }
          rescue Nexus::CanonicalJson::UnsupportedValue => error
            refused(body, "result_unstorable", error.message)
          end

          def expanded(body, built, tails)
            key = body.fetch("key")
            @inlined << key
            @placers << key
            steps = scope(built.steps, "#{key}/")
            tails[key] = Shape.exits(steps).sole
            @world&.expanded(key, tails[key])
            { Shape::EXPANSION => expansion(body).merge("steps" => steps) }
          end

          # What the expansion's roots wait on is what the stage waited on: its `after:` and, for a stage
          # that read results, its `results:`, which the drawing reads back as the stage's own.
          def expansion(body)
            if @world
              results = Array(body["results"])
              { "key" => body.fetch("key"), "after" => Array(body["after"]) | results, "results" => results }
            else
              body.slice("key", "after")
            end
          end
      end
    end
  end
end
