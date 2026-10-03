require "json"

module Rho
  module Cli
    # THE ONE CONVERSATION VERB'S COMPOSITION (`run` is the control plane's single conversational courtesy — reasonix's `run`, over rho's daemon). Open a conversation,
    # follow its one turn, deny every call that parks for an approver
    # nobody here is, print the answer, exit by outcome; stop the loop
    # it opened when it cannot finish on its own. Built from the core's
    # primitives alone, including durable input correlation, and the
    # terminal's renderers; no route is named
    # here (`test/code_style/core_surface_test.rb`). rho-dev's `do`,
    # `follow`, `deny`, `result` and `stop` format the same five, one each.
    #
    # THE EXIT TABLE: 0 the turn completed; 1 it failed on a terminal
    # loop, was canceled by someone else, or the daemon refused; 2 the
    # run could not finish on its own — the model's ask (`awaiting_human`),
    # a turn-shaped hold (`failed` on a live loop, which only a retry or an answer reopens), a park with no key to deny, or the
    # deadline — the loop STOPPED first (a one-shot owns its turn; a
    # product home has no other verb); 130 a signal, stopped the same way.
    # An `approval_required` park with keys is DENIED and the run goes on:
    # reasonix's letter — in a non-interactive run there is no prompt to
    # answer, the call fails closed, the model reads the refusal.
    module Run
      FORMATS = %w[text json stream-json].freeze
      DENY_REASON = "rho run: non-interactive; nobody can approve".freeze
      NO_DELIVERABLE = "(none — this loop resolved no deliverable)".freeze
      # The verdicts the follow ends with (`TurnFollow::VERDICTS`), and
      # what each is worth.
      EXIT = { completed: 0, failed: 1, canceled: 1, refused: 1, hold: 2, ask: 2, keyless: 2, timeout: 2,
               interrupted: 130 }.freeze
      SUBTYPE = { completed: "success", failed: "failed", canceled: "canceled", refused: "failed",
                  hold: "needs_person", ask: "needs_person", keyless: "needs_person", timeout: "timeout",
                  interrupted: "canceled" }.freeze

      # THE RESULT OBJECT (json, and stream-json's last line): fields are
      # never removed within the shape; a consumer ignores unknown ones.
      # `model_switches` is every step the kernel moved to another model —
      # `{task, from, to, reason, category?}`, off its `task_status`
      # narration (`reason` `model_refused` when the answerer's fallback
      # re-ran a declined step) — and `refusals` every round a provider
      # declined — `{task, model, category?}`, off its `round_result` —
      # whether a fallback then served the step or it stood; a result the
      # fallback produced is not the asked model's, and these say so.
      Outcome = Data.define(:exit_status, :subtype, :status, :reason, :duration_ms, :denied_calls,
                            :conversation_id, :turn_id, :loop_id, :result, :model_switches, :refusals) do
        def is_error = subtype != "success"

        def to_h
          { "type" => "result", "subtype" => subtype, "is_error" => is_error, "status" => status, "reason" => reason,
            "duration_ms" => duration_ms, "denied_calls" => denied_calls, "conversation_id" => conversation_id,
            "turn_id" => turn_id, "loop_id" => loop_id, "result" => result, "model_switches" => model_switches,
            "refusals" => refusals }
        end
      end

      # `options` as Thor parsed them (symbol keys); `fold` is the
      # dispatcher's fold chain for `run` (an extension's flags into the
      # body); `err` is where the one human sentence goes in text mode.
      # Answers the outcome — the exit status is the dispatcher's to raise.
      def self.call(cli, prompt, options, err: $stderr, &fold)
        Session.new(cli, options, err: err).call(prompt, &fold)
      end

      # One run's state: the ids as they are learned, the verdict, what
      # was denied. The stream is `TurnFollow`'s to read; what it settled
      # on is copied back here once, for the lines and the object.
      class Session
        def initialize(cli, options, err:)
          @cli = cli
          @core = cli.core
          @out = cli.out
          @err = err
          @options = options
          @format = options.fetch(:"output-format", "text")
          @print = options[:print] == true
          @timeout = options[:timeout]
          @seen = {}
          @denied = []
          @conversation = nil
          @turn = nil
          @loop = nil
          @status = nil
          @failure_reason = nil
          @attention = nil
          @reason = nil
          @switches = []
          @refusals = []
        end

        def call(prompt, &fold)
          @started = monotonic
          verdict = open(prompt, &fold) || follow
          stopped = stop! if EXIT.fetch(verdict) >= 2
          answer = read_result
          outcome = Outcome.new(exit_status: EXIT.fetch(verdict), subtype: SUBTYPE.fetch(verdict),
            status: stopped&.dig("status") || answer&.dig("status") || @status, reason: reason_of(verdict),
            duration_ms: ((monotonic - @started) * 1000).round, denied_calls: @denied.length,
            conversation_id: @conversation, turn_id: @turn, loop_id: @loop, result: answer&.dig("output"),
            model_switches: @switches.dup, refusals: @refusals.dup)
          report(outcome, verdict)
          outcome
        end

        private

          # ---- the Core primitives, composed ----

          # `POST /conversations` through the core; the header in text
          # mode. Answers a verdict only when the daemon refused.
          def open(prompt, &fold)
            answer = @core.open_conversation(
              workspace_public_id: @options[:workspace],
              prompt: prompt, model: @options[:model], instructions: @options[:instructions],
              directory: @options[:dir], runner: @options[:runner], agent: @options[:agent],
              attachments: Array(@options[:attach]), &fold
            )
            @conversation = answer.dig("conversation", "public_id")
            @turn = answer.dig("turn", "public_id")
            @loop = answer.dig("loop", "public_id")
            @pending_input = answer.fetch("input") if answer["pending"]
            @cli.report_turn(answer, pending_hint: nil) if rendering?
            nil
          rescue Rho::Error => error
            @reason = error.message
            :refused
          end

          # THE FOLLOW: `TurnFollow` over the conversation's events with the
          # deadline on the socket; every frame to the writer first (its
          # `on_frame`), the `loop:` line when the loop becomes known, the
          # park denied key by key and the run going on. What it settled
          # on — the ids, the turn's word, the failure, the attention, the
          # sentence — is copied back for the lines and the object.
          def follow
            pending_verdict = await_input if @pending_input
            return pending_verdict if pending_verdict

            machine = TurnFollow.new(
              core: @core, conversation: @conversation, turn: @turn, loop: @loop, deadline: remaining,
              on_frame: method(:write), on_loop: method(:announce_loop), on_park: method(:deny_all)
            )
            verdict = machine.follow
            @turn = machine.turn
            @loop = machine.loop
            @status = machine.status
            @failure_reason = machine.failure&.reason
            @attention = machine.attention
            @reason = machine.reason
            verdict
          end

          def await_input
            anchor = @pending_input.fetch("position")
            reader = InputMaterialization.new(input_public_id: @pending_input.fetch("public_id"),
              position: CybrosAgent::KernelFeed::Position.new(cursor: anchor.fetch("cursor"), sequence: anchor.fetch("sequence")),
              replay: ->(cursor) { @core.host_events(@conversation, after: cursor) })
            loop do
              return :timeout if @timeout && monotonic - @started >= @timeout

              reader.refresh
              if reader.result
                @turn, @loop = reader.result.turn, reader.result.loop
                announce_loop(@loop) if @loop
                return nil
              end
              if reader.blocked_reason
                @reason = reader.blocked_reason
                return :refused
              end
              sleep 1
            end
          rescue Rho::Error => error
            @reason = error.message
            :refused
          rescue Interrupt, SignalException
            :interrupted
          end

          # In text mode, announce the loop when the receipt or stream identifies it.
          def announce_loop(loop_id)
            @out.puts "loop:         #{loop_id}" if rendering?
          end

          # THE PARK: reasonix's letter — in a non-interactive run there is
          # no prompt to answer; each key is denied with the run's reason,
          # counted, and the model reads the refusal. A deny the daemon
          # refuses raises through to the machine, which ends the follow
          # `keyless`: a call nobody here can decide.
          def deny_all(loop_id, keys)
            keys.each do |key|
              @core.deny(loop_id, key, reason: DENY_REASON)
              @denied << key
              @out.puts "  REFUSED #{key} — non-interactive run" if rendering?
            end
          end

          # The loop this run opened, stopped: forcefully — a one-shot owns
          # its turn. A loop already over is not a failure of the stop.
          def stop!
            return nil if @conversation.nil?

            @core.stop(@conversation, force: true)
          rescue Rho::Error
            nil
          end

          # What the loop produced, when one is known: whole on 0/1, the
          # partial on 2/130; nothing to read is nothing.
          def read_result
            return nil if @loop.nil?

            @core.result(@loop)
          rescue Rho::Error
            nil
          end

          def remaining
            return nil if @timeout.nil?

            [@timeout - (monotonic - @started), 0.001].max
          end

          def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # ---- what is printed ----

          def rendering? = @format == "text" && !@print

          def write(type, payload)
            note(type, payload)
            if @format == "stream-json"
              @out.puts JSON.generate(payload.merge("type" => type))
            elsif rendering?
              render(type, payload)
            end
          end

          # THE DECLINED ROUNDS AND THE SWITCHES, read off the pushed items
          # for the object; under `-p` each switch is said once on stderr,
          # the one human line a fallback's answer owes its reader (the
          # table says it in text mode, the object in the structured ones).
          def note(type, payload)
            case type
            when "task_status"
              change = payload["model_change"]
              note_switch(payload.fetch("task_key"), change) if change
            when "round_result"
              if Reporting::DECLINED.include?(payload["finish_quality"])
                @refusals << { "task" => payload.fetch("task_key"), "model" => payload["model"],
                               "category" => payload["refusal_category"] }.compact
              end
            else nil
            end
          end

          def note_switch(task, change)
            switch = { "task" => task, "from" => change["from"], "to" => change["to"], "reason" => change["reason"],
                       "category" => change["category"] }.compact
            @switches << switch
            return unless @format == "text" && @print

            category = switch["category"] ? ": #{switch["category"]}" : ""
            @err.puts "rho run: #{task} switched from #{switch["from"]} to #{switch["to"]} (#{switch["reason"]}#{category})"
          end

          # The text rendering of the stream, the shared renderers: the
          # table as it moves, the checklist, the reply as it is written —
          # never the reasoning channel.
          def render(type, payload)
            case type
            when "snapshot"
              @cli.report_tasks(payload, @seen)
              @cli.report_todo(payload, @seen)
              @cli.report_attention(payload) if payload["attention"]
              @out.partial(payload["text"], length: payload["text_length"])
            when "text_delta" then @out.text(payload["text"].to_s)
            when "stream_reset" then @out.reset
            when "task_status", "round_result"
              @cli.report_tasks({ "tasks" => [payload] }, @seen)
              @cli.report_todo({ "tasks" => [payload] }, @seen)
            when "progress" then @cli.report_todo({ "frames" => [payload] }, @seen)
            when "input_accepted"
              if payload["deliver_at"] || Rho::HostRun::WRAPPED_ORIGINS.include?(payload["origin"])
                @cli.report_tasks({ "mailed" => [payload] }, @seen)
              end
            when "attention_required" then @cli.report_attention("attention" => payload)
            else nil
            end
          end

          # The end: `status:` and the answer (text), the answer alone
          # (`-p`), the object (json, stream-json); the one human sentence
          # on stderr in the human modes only — a structured mode carries
          # every error inside the object and never also prints a line.
          def report(outcome, verdict)
            if @format == "text"
              report_text(outcome) unless verdict == :refused
              sentence = sentence_of(verdict)
              @err.puts "rho run: #{sentence}" if sentence
            else
              @out.puts JSON.generate(outcome.to_h)
            end
          end

          def report_text(outcome)
            answer = outcome.result.nil? ? NO_DELIVERABLE : outcome.result
            if @print
              @out.puts answer
            else
              @out.puts "status:    #{outcome.status}"
              @out.puts
              @out.puts answer
            end
          end

          def reason_of(verdict)
            case verdict
            when :failed, :hold then @failure_reason
            when :ask, :keyless then @attention&.first
            when :timeout then "timeout"
            when :interrupted then "interrupted"
            when :refused then @reason
            else nil
            end
          end

          def sentence_of(verdict)
            case verdict
            when :hold
              "needs a person (the turn failed and the loop is holding#{" — #{@failure_reason}" if @failure_reason}); " \
                "the run stopped it"
            when :ask then "needs a person (#{@attention.first} — #{@attention.last.join(", ")}); the run stopped it"
            when :keyless then "needs a person (approval_required — #{@reason || "no key to deny"}); the run stopped it"
            when :timeout then "timed out after #{@timeout} s; the run stopped it"
            when :interrupted then "interrupted; the run stopped it"
            when :refused then @reason
            else nil
            end
          end
      end
    end
  end
end
