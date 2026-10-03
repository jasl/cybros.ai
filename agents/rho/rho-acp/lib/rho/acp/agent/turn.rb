module Rho
  module Acp
    class Agent
      # THE PROMPT TURN, on the turn thread:
      #
      # 1. The content blocks → words + attachments. A leading
      # `/word` naming a surface command runs it: `/retry` reopens
      #    the holding turn and re-follows it; `/abandon` and `/compact`
      #    answer `end_turn` with no model turn. Any other `/word` is posted
      #    VERBATIM.
      # 2. Holding an ask ? → `Core#answer(loop, key, text)` and the
      #    SAME turn is followed on. Else `Core#say(session, text, mode:
      #    "queue", attachments:, model:, approval_mode: nil for bypass,
      #    else the word)` → `turn`/`loop`; on `pending: true` the daemon's
      #    durable host events are polled from the receipt's position
      #    until that exact input materializes (no deadline; the editor
      #    cancels). Other senders and between-turn summaries cannot
      #    supply its turn. The attachments are deleted once `say` answered.
      # 3. `TurnFollow` over `Core#loop_events` on this thread, the frames
      # through `Mapping`, the park to `Permissions`.
      # 4. The response, by the follow's verdict:
      #
      #    cancel_requested (whatever settled)  {stopReason: cancelled}
      #    completed                            end_turn
      #    canceled (by anyone else)            cancelled
      #    failed on a TERMINAL loop            -32603 {failure_reason; data {loop, turn, failure_reason_key}}
      #    failed on a LIVE loop (a hold)       -32603 {failure_reason; data {hold: true, loop, retry, abandon}}
      #                                         — the session keeps the conversation; `/retry` and `/abandon` reopen it
      #    the ask without `elicitation.form`   the question streamed, end_turn, the ask held for the next prompt
      #    the ask with the form, answered      the same turn re-joined (a NEW `TurnFollow` naming it)
      #    a keyless park                       end_turn (nobody here can decide it; the daemon keeps following)
      #    the stream ended without a word      `TurnFollow` settles it on the row, else -32603
      #    conversation_ended under the follow  -32002, and every later call on the session
      #
      #    `refusal`, `max_tokens`, `max_turn_requests` are never produced:
      #    rho has no ceilings and the kernel has no "the model refused"
      #    outcome; `refusal` would tell the editor to drop the prompt from
      #    history, which is false.
      #
      # THE RE-JOIN WAITS FOR THE FOLLOWER (`catch_up`): the daemon's
      # snapshot moves only when the kernel's feed item lands — an answer
      # clears the loop's attention through the converger's `turn_status`
      # note after commit, a retry reopens the turn as `running` — and a
      # re-join issued the moment `Core#answer`/`Core#retry` returned can
      # beat that item over loopback. A stale `awaiting_human` would ask
      # the editor the same question twice (and the second `answer` is the
      # daemon's refusal); a stale `failed` would answer the old hold to a
      # retry that took. So before the re-join the row is polled until it
      # left the state the verb resolved, the cancel flag ends the wait,
      # and past `CATCH_UP_SECONDS` the follow reads the row as it stands —
      # the honest answer when the verb did not take (the model asked
      # again, the retry failed again).
      class Turn
        POLL_SECONDS = 0.25
        MATERIALIZATION_POLL_SECONDS = 1
        CATCH_UP_SECONDS = 5
        # The sentence for a `say` the daemon answered 200 with `blocked`
        # — the kernel's word in a DOCUMENT, not a refusal — -32602 with
        # the reason; the daemon's `input_blocked` REFUSAL rides
        # `Errors.translate` by its code.
        BLOCKED = "the kernel blocked the input".freeze

        # The follow was cut short by a `session/cancel`.
        class Cancelled < StandardError; end

        class << self
          # Polls the session's row until `moved` answers true for it, the
          # session's cancel flag is set (`Cancelled`), the daemon stops
          # answering the row (the follow will say so), or `bound` passes.
          def catch_up(core, session, bound: CATCH_UP_SECONDS)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + bound
            loop do
              raise Cancelled if session.cancel_requested?

              row = begin
                core.loop_row(session.id)
              rescue Rho::Error
                return nil
              end
              return nil if yield(row) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

              sleep POLL_SECONDS
            end
          end

          # Whether the row still parks the model's ask on `key`.
          def asking?(row, key)
            attention = Hash.try_convert(row["attention"]) || {}
            attention["reason"] == Replay::ASKING && Array(attention["blocked_task_keys"]).include?(key)
          end
        end

        def initialize(agent, session, inbound, core)
          @agent = agent
          @session = session
          @inbound = inbound
          @core = core
          @params = Hash.try_convert(inbound.params) || {}
        end

        # Release the slot before publishing any reply: the client can
        # send its next prompt as soon as it receives these bytes.
        def call
          result = begin
            @inbound.on_cancel { Thread.new { Permissions.cancel(@agent, @session, @agent.core) } }
            raise Refusal.not_found("the conversation #{@session.id} ended") if @session.ended

            run
          rescue Cancelled
            stop_reason(Acp::Methods::StopReason::CANCELLED)
          ensure
            @session.release_prompt
          end
          @inbound.respond(result)
        rescue StandardError => error
          refusal = Errors.translate(error)
          @inbound.fail(refusal.code, refusal.message, data: refusal.data) unless @inbound.answered?
        end

        # THE FOLLOW, public to `Commands.run` (`/retry` re-follows the
        # holding turn): one `TurnFollow` per join, re-joined after an
        # answered ask; answers the PromptResponse document.
        def follow(turn, loop_id)
          loop do
            raise Cancelled if @session.cancel_requested?

            state = @session.turn_state(turn, loop: loop_id)
            mapping = Mapping.new(agent: @agent, session: @session, core: @core, state: state)
            permissions = Permissions.new(agent: @agent, session: @session, core: @core, mapping: mapping)
            machine = Rho::Cli::TurnFollow.new(core: @core, conversation: @session.id, turn: turn, loop: loop_id,
              on_frame: mapping.method(:frame), on_park: permissions.method(:park))
            machine.follow
            loop_id ||= machine.loop
            @session.last_loop = loop_id if loop_id
            raise Cancelled if @session.cancel_requested?

            answer = settle(machine, permissions, turn, loop_id)
            return answer unless answer == :rejoin
          end
        end

        private

          def run
            rendered = Content.render(@params["prompt"], dir: attachment_dir)
            begin
              word = Commands.surface_word(rendered.text)
              return Commands.run(@agent, @session, @core, word, self) if word

              turn, loop_id = @session.held ? answer_held(rendered.text) : open(rendered)
            ensure
              rendered.discard
            end
            raise Cancelled if @session.cancel_requested?

            follow(turn, loop_id)
          end

          def attachment_dir = File.join(@agent.home.tmp_root, "acp", @session.id)

          # THE HELD ASK ANSWERED: the same turn is followed on, once the
          # follower saw the ask resolve.
          def answer_held(text)
            hold = @session.held
            @session.held = nil
            @core.answer(hold.loop, hold.key, text)
            Turn.catch_up(@core, @session) { |row| !Turn.asking?(row, hold.key) }
            [hold.turn, hold.loop]
          end

          # The say, and the ids it answered or the poll that finds them;
          # the port's registration re-asserted first.
          def open(rendered)
            Environment.assert(@agent, @core, @session)
            document = @core.say(@session.id, rendered.text, mode: "queue", attachments: rendered.attachments,
              model: @session.model, approval_mode: approval_mode)
            unless document["pending"]
              return remember(document.dig("turn", "public_id"), document.dig("loop", "public_id"))
            end

            blocked = document["blocked"]
            raise Refusal.invalid_params("#{BLOCKED} (#{blocked})") if blocked

            poll(document.fetch("input"))
          end

          def approval_mode = @session.mode == DEFAULT_MODE ? nil : @session.mode

          # The receipt keeps the pre-POST cursor so even a materialization
          # preceding this read remains attributable to the accepted input.
          def poll(input)
            position = input.fetch("position")
            materialization = Rho::InputMaterialization.new(input_public_id: input.fetch("public_id"),
              position: CybrosAgent::KernelFeed::Position.new(cursor: position.fetch("cursor"), sequence: position.fetch("sequence")),
              replay: ->(cursor) { @core.host_events(@session.id, after: cursor) })
            loop do
              raise Cancelled if @session.cancel_requested?

              materialization.refresh
              raise Cancelled if @session.cancel_requested?

              result = materialization.result
              return remember(result.turn, result.loop) if result

              blocked = materialization.blocked_reason
              raise Refusal.invalid_params("#{BLOCKED} (#{blocked})") if blocked

              sleep MATERIALIZATION_POLL_SECONDS
            end
          end

          def remember(turn, loop_id)
            @session.last_turn = turn
            @session.last_loop = loop_id
            [turn, loop_id]
          end

          def settle(machine, permissions, turn, loop_id)
            case machine.verdict
            when :completed then stop_reason(Acp::Methods::StopReason::END_TURN)
            when :canceled, :interrupted then stop_reason(Acp::Methods::StopReason::CANCELLED)
            when :failed then failed(machine, turn, loop_id)
            when :hold then hold(machine, loop_id)
            when :ask then asked(machine, permissions, turn, loop_id)
            when :keyless then stop_reason(Acp::Methods::StopReason::END_TURN)
            when :timeout then raise Refusal.internal(machine.reason || "the follow timed out")
            else refused(machine)
            end
          end

          def failed(machine, turn, loop_id)
            failure = machine.failure
            raise Refusal.internal(failure&.reason || "the turn failed",
              data: { "loop" => loop_id, "turn" => turn, "failure_reason_key" => failure&.key }.compact)
          end

          def hold(machine, loop_id)
            raise Refusal.internal(machine.failure&.reason || "the turn is holding",
              data: { "hold" => true, "loop" => loop_id, "retry" => "/retry", "abandon" => "/abandon" })
          end

          # The ask: a park with keys never lands here (`on_park` takes
          # every key); the model's question is answered through the
          # form and re-joined, or held.
          def asked(machine, permissions, turn, loop_id)
            reason, keys = machine.attention
            key = keys.first
            return stop_reason(Acp::Methods::StopReason::END_TURN) if key.nil? || reason == "approval_required"

            outcome = permissions.ask(loop_id, key)
            raise Cancelled if @session.cancel_requested?
            if outcome == :continue
              Turn.catch_up(@core, @session) { |row| !Turn.asking?(row, key) }
              return :rejoin
            end

            @session.held = Hold.new(loop: loop_id, key: key, turn: turn)
            stop_reason(Acp::Methods::StopReason::END_TURN)
          end

          def refused(machine)
            raise Refusal.not_found("the conversation #{@session.id} ended") if @session.ended

            raise Refusal.internal(machine.reason || Rho::Cli::TurnFollow::STREAM_ENDED)
          end

          def stop_reason(word) = { "stopReason" => word }
      end
    end
  end
end
