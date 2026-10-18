require "cybros_agent"

module Rho
  module Cli
    # The settle machine follows a conversation's events (`Core#follower_events`), each
    # matching frame handed to `on_frame` BEFORE the machine reads it, and the
    # turn's word read off the frames until a VERDICT settles the follow.
    # Lifted whole from `Cli::Run`, which is re-pointed onto it: nothing
    # here prints — the terminal's lines are `Run`'s, behind the callbacks
    # — and the ACP surface maps the same frames onto `session/update`
    # and reads the same verdicts into its `PromptResponse`.
    # Built from the core's primitives alone
    # (`follower_events`, `follower_row`) and the SDK execution observer; no route is named here
    # (`test/code_style/core_surface_test.rb`).
    #
    # THE VERDICTS (`VERDICTS`; `Run::EXIT` prices them):
    #   completed    the turn completed
    #   canceled     the turn was canceled — by anyone (`rho stop`, the webui)
    #   failed       direct inference failed, or the turn failed on a terminal run
    #   hold         the turn failed on a LIVE run: only a
    #                retry or an answer reopens it; the stream never closes
    #                on a hold, so the verdict is the frame's, not the socket's
    #   ask          a person is needed: the model's ask (`awaiting_human`),
    #                or a park with keys and no `on_park` to decide them —
    #                `attention` carries `[reason, keys]`
    #   keyless      a park nobody can decide: no key, the run not known
    #                yet, or `on_park` refused (a `Rho::Error`) — `reason`
    #   timeout      the socket's deadline fired (`Core::Deadline`)
    #   interrupted  a signal
    #   refused      the daemon refused (`Rho::Error`), or the stream ended
    #                and the row settles nothing — `reason` is the sentence
    #
    # A terminal word (`completed`, `canceled`, `failed` on a terminal
    # run) is REMEMBERED and the stream read to its end — the settle's own
    # text remainder lands after it, and the daemon closes on
    # `turn_settled` — while a hold or an ask, which never closes the
    # stream, THROWS out of the read (`:settled`): the daemon keeps
    # following, this reader just stops, and a re-join naming the same
    # `turn:` filters to it. A stream that ends
    # without a word settles on the daemon's row (`settle_from_row`).
    #
    # THE FILTER: a `turn_status` (or a complete snapshot) for another
    # turn moves nothing — the kernel's between-turn summary runs on its
    # own run, and a late word about a turn left behind is not this one's.
    # A stream closed by an earlier turn is rejoined while the requested
    # turn is durably live, with the same deadline across all subscriptions.
    #
    # THE CALLBACKS, each optional:
    #   on_frame (type, payload)  each matching frame, before the machine reads it
    #   on_run  (run_id)        once, when the run becomes known from a
    #                             frame or the row — never for one named at
    #                             construction (`Run` prints its line then)
    #   on_park  (run_id, keys)  a park (`approval_required`) with keys the
    #                             follow has not yet handed over; answering
    # CONTINUES the follow (`Run` denies each; the ACP surface hands them to its park thread), raising `Rho::Error` ends
    #                             it `keyless` with the sentence
    class TurnFollow
      RUN_TERMINAL = CybrosAgent::Api::RUN_TERMINAL_STATUSES
      VERDICTS = %i[completed canceled failed hold ask keyless timeout interrupted refused].freeze
      RUN_UNKNOWN = "the run is not known yet".freeze
      STREAM_ENDED = "the stream ended before the turn settled".freeze
      CATCH_UP_POLL_SECONDS = 0.25
      # The kernel's reason for the model's ask (`EvaluateQuiescence::ASKING_REASON`).
      ASKING = "awaiting_human".freeze

      # A failed turn's two kernel fields (`turn_status`, the row):
      # the reason as a sentence, and its key when the frame carried one.
      Failure = Data.define(:reason, :key)

      # `turn`/`run` as the caller already knows them (the open's 201,
      # a re-join); `status`/`run_status` the turn's last words;
      # `attention` the `[reason, keys]` that ended an `ask`/`keyless`
      # follow; `reason` the sentence behind `refused`/`keyless`;
      # `settled_row` the daemon's row when the stream ended without a
      # word; `decided` the park keys handed to `on_park` so far;
      # `verdict` the follow's answer once it has one.
      attr_reader :turn, :variant, :run_public_id, :status, :run_status, :attention, :reason, :settled_row, :decided, :verdict

      def initialize(core:, conversation:, turn: nil, variant: nil, run_public_id: nil, deadline: nil, on_frame: nil, on_run: nil, on_park: nil)
        @core = core
        @conversation = conversation
        @turn = turn
        @variant = variant
        @run_public_id = run_public_id
        @deadline = deadline
        @on_frame = on_frame
        @on_run = on_run
        @on_park = on_park
        @status = nil
        @run_status = nil
        @failure_reason = nil
        @failure_reason_key = nil
        @attention = nil
        @reason = nil
        @settled_row = nil
        @decided = []
        @verdict = nil
        @word = nil
        @stream_turn = nil
        @stream_variant = nil
        @stream_run = nil
        @checked_variants = {}
      end

      # The subscription, the deadline on the socket (`Core#follower_events`);
      # answers the verdict. A `Rho::Error` here is the daemon's refusal
      # of the follow itself (an unfollowed host, a dead socket) — the
      # deadline is told apart by class, never by sentence.
      def follow
        @expires_at = monotonic + @deadline if @deadline
        @verdict = settle
      end

      # The failed turn's reason and key, when the turn failed; nil otherwise.
      def failure
        return nil unless @status == "failed"

        Failure.new(reason: @failure_reason, key: @failure_reason_key)
      end

      private

        def settle
          Kernel.loop do
            outcome = read_stream
            return outcome unless outcome == :rejoin

            sleep [CATCH_UP_POLL_SECONDS, remaining_deadline].compact.min
          end
        rescue Rho::Core::Deadline
          :timeout
        rescue Interrupt, SignalException
          :interrupted
        rescue Rho::Error => error
          @reason = error.message
          :refused
        end

        def read_stream
          catch(:settled) do
            @core.follower_events(@conversation, deadline: remaining_deadline) do |type, payload|
              was_following = @turn && @stream_turn == @turn && !foreign_run?(@stream_run) && !foreign_variant?(@stream_variant)
              incoming = type == "snapshot" ? payload["turn"] : payload["turn_public_id"]
              incoming_variant = type == "snapshot" ? payload["variant"] : payload["variant_public_id"]
              incoming_run = payload["run_public_id"]
              known_variant = @checked_variants.key?(incoming_variant)
              snapshot = continue_fallback(incoming, incoming_variant) if %w[snapshot turn_variant turn_status].include?(type)
              next if known_variant && type != "snapshot" && foreign_variant?(incoming_variant)

              if foreign_turn?(incoming) || foreign_run?(incoming_run) || foreign_variant?(incoming_variant)
                if type == "snapshot" || (%w[turn_variant turn_status].include?(type) && (was_following || @word))
                  recovered = recover_turn(snapshot: snapshot)
                  throw :settled, recovered if recovered
                end
                @stream_turn, @stream_variant, @stream_run = incoming, incoming_variant, incoming_run if type == "snapshot"
                next
              end
              if incoming && %w[snapshot turn_variant turn_status].include?(type)
                @stream_turn, @stream_variant, @stream_run = incoming, incoming_variant, incoming_run
              end
              next if (foreign_turn?(@stream_turn) || foreign_run?(@stream_run) || foreign_variant?(@stream_variant)) && type != "closed"

              @on_frame&.call(type, payload)
              advance(type, payload)
            end
            @word || settle_from_row
          end
        end

        def remaining_deadline
          return unless @expires_at

          remaining = @expires_at - monotonic
          raise Rho::Core::Deadline, "the follow timed out" unless remaining.positive?

          remaining
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # ---- the state machine ----

        def advance(type, payload)
          case type
          when "snapshot"
            learn(payload["run_public_id"], payload["turn"], payload["variant"])
            settle_on(payload, payload["turn"]) if payload["complete"] && payload["turn"]
            react(payload["attention"]) if payload["attention"]
          when "turn_status"
            learn(payload["run_public_id"], payload["turn_public_id"], payload["variant_public_id"])
            settle_on(payload, payload["turn_public_id"])
          when "attention_required" then react(payload)
          when "closed"
            if payload["reason"] == "host_ended"
              @reason = "this daemon stopped following the host; it may be unavailable"
              throw :settled, :refused
            end
            throw :settled, (@word || settle_from_row)
          else nil
          end
        end

        # The ids as the first frame carries them (a `pending` open had
        # none); `on_run` is told the first time the run is known.
        def learn(run_id, turn_id, variant_id = nil)
          return if foreign_turn?(turn_id)

          @turn = turn_id if @turn.nil? && turn_id
          @variant = variant_id if @variant.nil? && variant_id
          return if run_id.nil? || @run_public_id

          @run_public_id = run_id
          @on_run&.call(run_id)
        end

        def foreign_turn?(turn_id) = turn_id && @turn && turn_id != @turn

        def foreign_run?(run_id) = run_id && @run_public_id && run_id != @run_public_id

        def foreign_variant?(variant_id) = variant_id && @variant && variant_id != @variant

        # Automatic fallback continues this accepted execution. A person's
        # regeneration, including its own fallback, has a different origin.
        # Inspect a newly encountered candidate once, not on every frame.
        def continue_fallback(turn_id, variant_id)
          return unless turn_id == @turn && @run_public_id.nil? && foreign_variant?(variant_id)
          return if @checked_variants.key?(variant_id)

          @checked_variants[variant_id] = true
          recover_execution
        end

        # The turn's word: `completed` and `canceled` end it; `failed`
        # ends direct inference or a terminal run and holds a live run. A frame
        # for another turn moves nothing.
        def settle_on(payload, turn_id)
          return if turn_id && @turn && turn_id != @turn

          @run_status = payload["run_status"] if payload.key?("run_status")
          @failure_reason = payload["failure_reason"] if payload.key?("failure_reason")
          @failure_reason_key = payload["failure_reason_key"] if payload.key?("failure_reason_key")
          status = payload["status"]
          return if status.nil?

          @status = status
          case status
          when "completed" then @word = :completed
          when "canceled" then @word = :canceled
          when "failed"
            throw :settled, :hold if @run_public_id && !RUN_TERMINAL.include?(@run_status)

            @word = :failed
          else nil
          end
        end

        # THE PARK AND THE ASK. `approval_required` with keys not yet
        # decided goes to `on_park` and the follow goes on; a park that
        # `on_park` refuses is a call nobody here can decide. The model's
        # `ask` (`awaiting_human`), a keyless park, a park with no
        # `on_park` — needs a person and ends the follow. ANY OTHER REASON
        # IS A HOLD'S: a halted run rests `needs_attention` with its
        # failure key as the reason (`halt_failure`), announced as
        # `attention_required` beside the run-locked `turn_status` note,
        # and on a conversation host the turn's own `failed` word is
        # settle's separate write — so this frame can land BEFORE it. It
        # moves nothing here: the turn's word settles the hold, never a person's answer to a question nobody asked.
        def react(attention)
          reason = attention["reason"]
          keys = Array(attention["blocked_task_keys"]) - @decided
          @attention = [reason, keys]
          throw :settled, :ask if reason == ASKING
          return unless reason == "approval_required"
          throw :settled, :keyless if keys.empty?
          if @run_public_id.nil?
            @reason = RUN_UNKNOWN
            throw :settled, :keyless
          end
          throw :settled, :ask if @on_park.nil?

          @on_park.call(@run_public_id, keys)
          @decided += keys
        rescue Rho::Error => error
          @reason = error.message
          throw :settled, :keyless
        end

        # The stream ended before the turn's word: the daemon's row says
        # where it got to; a row that says nothing terminal is a failure
        # to read the end, named.
        def settle_from_row
          @settled_row = @core.follower_row(@conversation)
          if foreign_turn?(@settled_row["turn"]) || foreign_run?(@settled_row["run_public_id"]) || foreign_variant?(@settled_row["variant"]) ||
              foreign_turn?(@stream_turn) || foreign_run?(@stream_run) || foreign_variant?(@stream_variant)
            recovered = recover_turn(rejoin: true)
            return recovered if recovered

            @reason = STREAM_ENDED
            return :refused
          end

          learn(@settled_row["run_public_id"], @settled_row["turn"], @settled_row["variant"])
          held = catch(:settled) do
            settle_on(@settled_row, @settled_row["turn"])
            nil
          end
          return held || @word if held || @word

          @reason = STREAM_ENDED
          :refused
        rescue Rho::Error => error
          @reason = error.message
          :refused
        end

        # A queued successor can already own the live snapshot by the time
        # this reader joins. Recover this turn's latest durable status,
        # without rendering or acting on its successor's frames.
        def recover_turn(rejoin: false, snapshot: nil)
          snapshot ||= recover_execution
          return if snapshot.nil?

          state = { "status" => snapshot.status, "run_status" => snapshot.run_status,
            "failure_reason" => snapshot.failure_reason, "failure_reason_key" => snapshot.failure_reason_key }
          recover_text(snapshot) if %w[completed canceled failed].include?(snapshot.status)
          settle_on(state, @turn)
          return @word if @word

          # A recovery read can repeat the pending approval while the surface
          # is still deciding it. Only new keys (or a truly keyless park) are
          # actionable here; live stream duplicate policy stays in #react.
          if snapshot.attention && (snapshot.attention.blocked_task_keys.empty? ||
              (snapshot.attention.blocked_task_keys - @decided).any? || snapshot.attention.reason != "approval_required")
            react({ "reason" => snapshot.attention.reason, "blocked_task_keys" => snapshot.attention.blocked_task_keys })
          end
          :rejoin if rejoin && %w[pending running].include?(snapshot.status)
        end

        def recover_execution
          return if @turn.nil? || (@variant.nil? && @run_public_id.nil?)

          execution = CybrosAgent::InputMaterialization::Result.new(turn: @turn, variant: @variant, run_public_id: @run_public_id)
          snapshot = Rho::InputExecution.new(core: @core, conversation: @conversation).for_execution(execution: execution).recover
          return if snapshot.nil?

          recovered = snapshot.execution
          if recovered.variant && recovered.variant != @variant
            @checked_variants[@variant] = true if @variant
            @variant = recovered.variant
          end
          learn(recovered.run_public_id, recovered.turn, recovered.variant)
          snapshot
        end

        def recover_text(snapshot)
          return if snapshot.variant.nil?

          text = snapshot.content.to_s
          @on_frame&.call("snapshot", { "turn" => @turn, "variant" => @variant, "run_public_id" => @run_public_id, "status" => snapshot.status,
            "text" => text, "text_length" => text.bytesize, "tasks" => [] })
        end
    end
  end
end
