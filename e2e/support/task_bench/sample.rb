require_relative "../../../nexus/app/services/agent_runs/round_replay/pairing"
require_relative "../../../nexus/lib/nexus/model_tool_calls"
require_relative "../manual_client"
require_relative "../output_caps"
require_relative "declared_set"
require_relative "door"
require_relative "emulator"
require_relative "objectives"

module E2E
  module TaskBench
    module Sample
      MESSAGES = 3
      QUIET = ->(_facts) { }

      module_function

      def call(client:, route:, style:, candidate:, objective:, index:, declared:, heartbeat: QUIET, pause: ManualClient::PAUSE)
        Draw.new(client: client, route: route, style: style, candidate: candidate, objective: objective, index: index,
          declared: declared, heartbeat: heartbeat, pause: pause).record
      end

      # One message's reading: the raw calls (the items it replays), the resolved ones (what the
      # objective and the read rule read), its text, its `messages[]` entry and its call's error.
      Turn = Data.define(:raw, :calls, :text, :message, :error)

      class Draw
        def initialize(client:, route:, style:, candidate:, objective:, index:, declared:, heartbeat:, pause:)
          @client = client
          @route = route
          @style = style
          @candidate = candidate
          @objective = objective
          @index = index
          @declared = declared
          @heartbeat = heartbeat
          @pause = pause
          @cap = OutputCaps.for(route.model)
          @instructions = DeclaredSet.instructions(candidate: candidate)
          @tools = DeclaredSet.symbolized_definitions(style: style, candidate: candidate)
        end

        def record
          base.merge(outcome)
        rescue StandardError => error
          base.merge(failed(error))
        end

        private

          def base
            { "objective" => @objective.id, "model" => @route.ref, "style" => @style, "sample" => @index,
              "max_output_tokens" => @cap, "candidate" => @candidate&.key }.compact
          end

          def outcome
            Emulator.open(fixture: @objective.fixture) do |emulator|
              converse([{ "role" => "user", "content" => @objective.text }], 1, [], emulator)
            end
          end

          # Message `n` over `input`; `said` holds the entries of the messages before it.
          def converse(input, n, said, emulator)
            turn = ask(input, n, emulator)
            messages = said + [turn.message]
            if turn.error
              ended(messages, "pass" => false, "error" => turn.error)
            elsif @objective.scored_first || !turn.message.fetch("read_class")
              ended(messages, scored(turn, n))
            elsif n == MESSAGES
              ended(messages, "pass" => false, "scout" => true, "scout_then_door" => false, "door_kind" => Door::SCOUT)
            else
              continued(input, n, messages, turn, emulator)
            end
          end

          # The reads answered, the next message asked; the emulator raising is the harness's own
          # fault, kept beside the messages it reached.
          def continued(input, n, messages, turn, emulator)
            replay = replayed(turn, emulator)
          rescue StandardError => error
            ended(messages, failed(error))
          else
            converse(input + replay, n + 1, messages, emulator)
          end

          def scored(turn, n)
            @objective.score(turn.raw, declared: @declared)
              .merge("text" => turn.text, "scored_message" => n, "scout" => false, "scout_then_door" => n > 1)
          rescue StandardError => error
            failed(error)
          end

          def ended(messages, outcome)
            last = messages.last.except("index", "called", "read_class", "error", "usage", "retries")
            { "messages" => messages }.merge(last, drawn(messages), outcome)
          end

          # THE DRAW'S SPEND AND RETRIES: every message's counts and bills summed key by key — a
          # settlement fact (`ManualClient::SETTLEMENT_FACTS`) kept only when the messages agree —
          # and every message's retries in order; each absent when no message carries one.
          def drawn(messages)
            usage = messages.filter_map { |message| message["usage"] }.reduce do |sum, one|
              sum.merge(one) { |key, a, b| ManualClient::SETTLEMENT_FACTS.include?(key) ? (a if a == b) : a + b }
            end
            retries = messages.flat_map { |message| message.fetch("retries", []) }
            { "usage" => usage&.compact, "retries" => retries.presence }.compact
          end

          def failed(error) = { "pass" => false, "error" => ManualClient.error_text(error) }

          # One call, retried as the kernel retries; its heartbeat beats before it is read.
          def ask(input, n, emulator)
            material = ManualClient.cached(@client, instructions: @instructions, input: input)
            called = ManualClient.retrying(pause: @pause) do
              @client.responses.create(model: @route.model, **material, tools: @tools, max_output_tokens: @cap)
            end
            turn = called.error ? unanswered(called, n) : read(called, n, emulator)
            @heartbeat.call(beat(turn.message, n))
            turn
          end

          # Read-class is judged under the draw's own copy (`Emulator#read_class?`).
          def read(called, n, emulator)
            raw = Nexus::ModelToolCalls.normalize(called.result.tool_calls)
            calls = raw.map { |call| Objectives::Call.from(call, @declared) }
            message = { "index" => n, "called" => calls.map(&:name).tally }
              .merge(ManualClient.facts(called.result, @route.lane), called.facts,
                "read_class" => emulator.read_class?(calls))
            Turn.new(raw: raw, calls: calls, text: called.result.output_text.to_s.strip[0, 200], message: message, error: nil)
          end

          def unanswered(called, n)
            error = ManualClient.error_text(called.error)
            Turn.new(raw: [], calls: [], text: "", message: { "index" => n, **called.facts, "error" => error }, error: error)
          end

          def beat(message, n)
            { "model" => @route.ref, "objective" => @objective.id, "sample" => @index, "index" => n,
              **message.slice("seconds", "usage", "retries", "error") }
          end

          # The message's calls, then each one's answer, in call order: consecutive calls fold into
          # one assistant message on the chat wire, as the model emitted them.
          def replayed(turn, emulator)
            calls = turn.raw.map do |call|
              { "type" => "function_call", "call_id" => call["id"], "name" => call["name"], "arguments" => call["arguments"] }
            end
            calls + turn.raw.zip(turn.calls).map { |raw, call| output(raw["id"], emulator.answer(call)) }
          end

          def output(call_id, result)
            text = result.is_error ? AgentRuns::RoundReplay::Pairing.marked(result.content) : result.content
            { "type" => "function_call_output", "call_id" => call_id, "output" => text,
              "is_error" => (true if result.is_error) }.compact
          end
      end
    end
  end
end
