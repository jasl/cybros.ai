require "json"
require "simple_inference"
require_relative "../../../nexus/lib/nexus/compose/evaluator"
require_relative "../../../nexus/lib/nexus/model_tool_calls"
require_relative "../bench_records"
require_relative "../manual_client"
require_relative "../output_caps"
require_relative "../provider_lanes"
require_relative "buckets"
require_relative "endpoints"
require_relative "inline"
require_relative "rehearsal"
require_relative "scoring"
require_relative "shape"
require_relative "styles"
require_relative "tools"

module E2E
  module ComposeBench
    # ONE SAMPLE: the objective as the user's message, the row's `compose` bytes and the harness
    # tools declared — and the STYLE's `task`/`ask` spelling beside them, compose's text rendered
    # under the same set — ONE call; if the script is refused, ONE repair call playing the kernel's
    # own refusal back as the tool result the model would really receive. Scored through the SHIPPED
    # evaluator, then the harness's lowering (`Shape`, whose reads are the kernel's `Reads`) against
    # the objective's picture — checked against the kernel itself by `Replay` in a launch; the
    # first script is also read for this bench alone — usable, the expanded picture, the mechanism
    # endpoints.
    class Probe
      SYSTEM = <<~TEXT.strip
        You are an engineering agent working in a repository. Answer the user's
        request by calling the tools available to you. Do not describe what you
        would do; make the calls.
      TEXT

      # THE OUTPUT CAP IS PER MODEL (`E2E::OutputCaps`, the one table the
      # text benches read), by the id the wire carries: every sample
      # records the cap it ran under beside the provider's finish.
      def self.max_output_tokens(model, env = ENV) = OutputCaps.for(model, env)

      # `route` (`ProviderLanes.route`): the catalog ref the sample records, the lane `client` calls
      # and the id its wire carries — the broker's `openrouter/…` or the direct DeepSeek floor, so
      # the floor the bench names is the one it measures. `candidate` (the RUN step's text probes): a
      # `lead_hints` candidate of the SDK pack's harness candidates — its line joins the probe's
      # instructions block after SYSTEM, the way a row's hint rides rho's lead outside the cached
      # prefix; nil is the baseline. A description entry is the TASK probe's (this matrix declares
      # `task`/`ask` beside compose alone). `pause` sleeps between a call's retries
      # (`ManualClient.retrying`).
      def initialize(client:, route:, row:, style: Styles.find("nexus"), candidate: nil,
                     max_output_tokens: self.class.max_output_tokens(route.model), pause: ManualClient::PAUSE)
        @client = client
        @route = route
        @row = row
        @style = style
        @candidate = candidate
        @max_output_tokens = max_output_tokens
        @pause = pause
      end

      # The instructions the sample runs under: SYSTEM, then the
      # candidate's hint lines when one is named.
      def instructions = [SYSTEM, *@candidate&.hint_texts].join("\n\n")

      # The sample record: every column the report and the gate read. The
      # cap and each call's finish and spend ride every record, reached or
      # not, so an exhausted cap is read as the cap and never as a choice
      # and a run's cost is read off its samples; the candidate's key rides
      # a candidate cell's records (absent = baseline).
      def sample(objective, index)
        base = { "objective" => objective.id, "row" => @row.id, "model" => @route.ref, "style" => @style.id,
                 "sample" => index, "max_output_tokens" => @max_output_tokens, "candidate" => @candidate&.key }.compact
        first = ask([{ "role" => "user", "content" => objective.text }], base.merge("index" => 1))
        return base.merge(unreached(first, objective)) if first[:script].nil?

        built = evaluate(first)
        scored = Scoring.score_built(objective, built, tool_names: Tools::NAMES)
        record = base.merge("reached" => true, "called" => first[:called], "script" => first[:script],
          "params" => first[:params], "text" => first[:text]).merge(facts(first), scored,
          reading(objective, first, built, scored))
        return record.merge("valid_after_repair" => scored["valid_first"],
          "right_after_repair" => scored["first_time_right"]) if scored["valid_first"]

        record.merge(repair(objective, first, scored, base))
      rescue StandardError => error
        base.merge("reached" => false, "error" => ManualClient.error_text(error))
      end

      private

        # No compose call: the control's success, every other objective's
        # miss. What it called instead is the finding.
        def unreached(first, objective)
          { "reached" => false, "called" => first[:called], "text" => first[:text],
            "error" => first[:error], "compose_zero" => objective.control? }.compact.merge(facts(first))
        end

        # The history is the Responses items' own shape, which the chat wire lowers to its
        # assistant and tool messages; a result item carries no `name`, since the Responses wire
        # sends every field as written. The repair call's finish and spend ride beside the first
        # call's, under its own names. A repair call that raised keeps its error beside
        # `no_second_call`, so a harness fault on the second call is never read as the model
        # declining to call again.
        def repair(objective, first, scored, base)
          history = [
            { "role" => "user", "content" => objective.text },
            { "type" => "function_call", "call_id" => first[:call]["id"],
              "name" => Nexus::Compose::TOOL_NAME, "arguments" => first[:call]["arguments"] },
            { "type" => "function_call_output", "call_id" => first[:call]["id"],
              "output" => "<tool_use_error>#{scored["refusal"]}: #{scored["detail"]}</tool_use_error>" },
          ]
          second = ask(history, base.merge("index" => 2))
          spent = facts(second).transform_keys { |key| "repaired_#{key}" }
          if second[:script].nil?
            { "repaired" => "no_second_call", "repaired_error" => second[:error],
              "valid_after_repair" => false, "right_after_repair" => false }.compact.merge(spent)
          else
            rescored = score(objective, second)
            { "repaired" => rescored["valid_first"] ? "valid" : "refused",
              "repaired_script" => second[:script], "repaired_detail" => rescored["detail"],
              "repaired_loud" => rescored["loud"], "repaired_silent" => rescored["silent"],
              "valid_after_repair" => rescored["valid_first"],
              "right_after_repair" => rescored["first_time_right"] }.compact.merge(spent)
          end
        end

        # The script as the SHIPPED evaluator builds it, once per call: the shared scorer and this
        # bench's own readings read the one result. The probe's tools are the harness's five.
        def evaluate(attempt)
          Nexus::Compose::Evaluator.call(script: attempt[:script], params: attempt[:params] || {}, tool_names: Tools::NAMES)
        end

        # The scorer is `Scoring`'s (shared with the evals).
        def score(objective, attempt) = Scoring.score_built(objective, evaluate(attempt), tool_names: Tools::NAMES)

        # THE TEXT BENCH'S OWN READINGS of the first script, under names the shared scorer does not
        # use. USABLE is the evals' floor bar (D4) read without a run: the script built (the
        # evaluator and the kernel's lowering accept it), its plan places a step once its
        # result-free stages are inlined, every stage source parses, and some placed node is not a
        # stage the kernel fails on its own script — a stage refused beside a surviving step is
        # recorded (`stage_refused`), since the kernel runs the rest around it. A result-free stage
        # is evaluated exactly as its run will be; the one difference is a result-reading stage,
        # read for its parse alone, so what it does with real output — a TypeError on a tool's
        # text, a step it places that fails — only the floor bar sees. The EXPANDED reading scores
        # the objective's picture on the inlined plan; a plan
        # holding a result-reading stage is OPAQUE, its expansion unknowable here, and is counted
        # out rather than scored. The REHEARSED reading (`Rehearsal`) judges every valid first script
        # on the plan the kernel would place in the objective's declared world, a result-reading
        # stage run over the results it would read; it only adds its own key beside these.
        def reading(objective, attempt, built, scored)
          if scored["valid_first"]
            inlined = Shape.inline(built.steps, tool_names: Tools::NAMES)
            graph = Shape.lower(inlined.steps)
            { **usable(inlined, graph), **expanded(objective, inlined, graph),
              "endpoints" => Endpoints.read(built, script: attempt[:script], expanded: inlined.steps),
              "rehearsed" => Rehearsal.reading(objective, built, scored, tool_names: Tools::NAMES) }
          else
            { "usable" => false, "unusable" => "refused #{scored["refusal"]}" }
          end
        end

        # An inlined stage is replaced by its expansion and survives only through it, as the kernel's
        # splice hands a stage's place to what it placed; a race's join is the kernel's barrier and
        # holds no work, so it never survives on its own.
        def usable(inlined, graph)
          unparsed = inlined.unparsed.first
          survivors = graph.nodes.reject { |node| node.kind == "join" }.map(&:key) - inlined.refused.map(&:key)
          if graph.nodes.empty?
            { "usable" => false, "unusable" => "placed nothing" }
          elsif unparsed || survivors.empty?
            stage = unparsed || inlined.refused.first
            { "usable" => false, "unusable" => "stage #{stage.key} refused #{stage.refusal}" }
          elsif inlined.refused.empty?
            { "usable" => true }
          else
            { "usable" => true, "stage_refused" => inlined.refused.map { |stage| "#{stage.key} #{stage.refusal}" } }
          end
        end

        def expanded(objective, inlined, graph)
          if inlined.opaque.empty?
            { "opaque" => false, "expanded" => Scoring.score_graph(objective, graph, placers: inlined.placers, refused: inlined.refused.map(&:key)) }
          else
            { "opaque" => true }
          end
        end

        # ONE CALL'S OWN FACTS (`ManualClient.facts`): the finish, its typed reason, the gem's
        # reading of it and the spend, none when the call raised; and the call's retries, answered
        # or not.
        def facts(call) = call.fetch(:facts, {})

        # One turn, retried as the kernel retries a transient failure (`ManualClient.retrying`). Its
        # heartbeat names the draw it belongs to (`draw`: the sample's fields and the call's ordinal
        # in it, 1 the first call and 2 the repair); `BenchRecords` keeps the call's facts alone.
        def ask(input, draw)
          material = ManualClient.cached(@client, instructions: instructions, input: input)
          called = ManualClient.retrying(pause: @pause) do
            @client.responses.create(
              model: @route.model, **material,
              tools: [@style.definition_for(@row).deep_symbolize_keys, *Tools::DECLARED, *@style.wire],
              max_output_tokens: @max_output_tokens
            )
          end
          turn = called.error ? failed(called.error) : answered(called.result)
          BenchRecords.heartbeat(ENV["E2E_BENCH_DIR"], { **draw, "error" => turn[:error], **facts(turn), **called.facts })
          turn.merge(facts: facts(turn).merge(called.facts))
        end

        def answered(result)
          calls = Nexus::ModelToolCalls.normalize(result.tool_calls)
          composed = calls.find { |call| call["name"] == Nexus::Compose::TOOL_NAME }
          arguments = composed && parse(composed["arguments"])
          # The provider's finish fact rides along: an empty completion
          # (no call, no text) is read off `finish`, never guessed at.
          { call: composed, called: calls.map { |call| call["name"] }.tally,
            text: result.output_text.to_s.strip[0, 300], facts: ManualClient.facts(result, @route.lane),
            script: arguments && arguments["script"], params: arguments && arguments["params"] }
        rescue StandardError => error
          failed(error)
        end

        def failed(error) = { call: nil, called: {}, script: nil, params: nil, error: ManualClient.error_text(error) }

        def parse(raw)
          JSON.parse(raw.to_s)
        rescue JSON::ParserError
          nil
        end
    end
  end
end
