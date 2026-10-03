module Rho
  class HostRun
    # The two ephemeral streams share the host's projection and lifecycle.
    # Neither consumes durable events nor owns the feed's cursor.
    module Streams
      # THE TRANSCRIPT PUMP, the twin of `follow` and public for the same
      # reason: a test drives it exactly as it drives the other one. This
      # feed is a TAIL — no replay, no cursor, nothing durable — so there is
      # no `KernelFeed` here to hold a position; there is a subscription, and
      # when it ends there is a new one.
      #
      # A REOPEN CLEARS DRAFT TEXT. A tail that was interrupted may have
      # dropped frames, so the draft is no longer known to be a prefix of
      # the final body. A sealed body stays intact; otherwise the
      # `stream_reset` it fans is what tells a person reading a terminal that
      # the text above it was left behind. `SubscriptionBackpressureError` (a
      # slow reader on a chatty model) is a loss like any other and takes the
      # same path.
      def follow_transcript
        idle = false
        until stopped_or_settled?
          unless streaming?
            # ONCE, not once a second: "why is there no text" is the first
            # question this feature creates, and the answer is one of three
            # flags a person can see here rather than guess at.
            @logger&.info("host.transcript_idle", host: public_id, host_type: @host.type,
                          live: @monitor.synchronize { @live }, stream: @stream,
                          realtime: !@realtime.nil?) unless idle
            idle = true
            @sleeper.call(POLL_SECONDS)
            next
          end
          idle = false

          begin
            subscription = @context.transcript(realtime: @realtime).call
            if stopped_or_settled? || !streaming?
              subscription.unsubscribe
              next
            end
            @monitor.synchronize { @transcript = subscription }
            @logger&.info("host.transcript_open", host: public_id, host_type: @host.type)
            reset_streams(preserve_settled: true)
            subscription.each { |item| apply_transcript(item) }
          rescue *CybrosAgent::KernelFeed::TRANSIENT_SUBSCRIBE_ERRORS => error
            @sleeper.call(transient_wait(error))
          ensure
            @monitor.synchronize { @transcript = nil }
            @logger&.info("host.transcript_closed", host: public_id, host_type: @host.type,
                          bytes: @monitor.synchronize { @text.length })
          end
        end
        self
      rescue StandardError => error
        # The same fire-and-forget line the events pump keeps: without it a
        # dead transcript pump is a turn that looks mute.
        @logger&.warn("host.transcript_failed", host: public_id, host_type: @host.type,
                      error_class: error.class.name,
                      error: CybrosAgent::Redaction.call(error.message))
        raise
      end

      # THE PROGRESS FEED: the frames the host's executors post
      # while their work happens — a `bash` tail under a claim, a process's
      # output under the host's binding — kept in a bounded ring for the
      # polling watcher and fanned to every listener as `progress` frames.
      # Opened while a socket is attached and somebody is live, like the
      # transcript's; nothing on it is durable, so a loss costs frames and
      # never a fact.
      def follow_progress
        until stopped_or_settled?
          unless following_progress?
            @sleeper.call(POLL_SECONDS)
            next
          end

          begin
            subscription = @context.progress(realtime: @realtime).call
            if stopped_or_settled? || !following_progress?
              subscription.unsubscribe
              next
            end
            @monitor.synchronize { @progress = subscription }
            @logger&.info("host.progress_open", host: public_id, host_type: @host.type)
            subscription.each { |frame| apply_progress(frame) }
          rescue *CybrosAgent::KernelFeed::TRANSIENT_SUBSCRIBE_ERRORS => error
            @sleeper.call(transient_wait(error))
          ensure
            @monitor.synchronize { @progress = nil }
            @logger&.info("host.progress_closed", host: public_id, host_type: @host.type)
          end
        end
        self
      rescue StandardError => error
        @logger&.warn("host.progress_failed", host: public_id, host_type: @host.type,
                      error_class: error.class.name,
                      error: CybrosAgent::Redaction.call(error.message))
        raise
      end

      private

        # Under the monitor is where the accumulators live: the transcript
        # pump writes them and the events pump clears them at a turn
        # boundary, and `snapshot` reads them from a third fiber.
        def streaming? = @monitor.synchronize { @stream && @live && !@realtime.nil? }

        # Not `@stream`: that knob is the text's (`--no-stream` leaves the
        # table alone); a watcher wants the frames whenever it is live.
        def following_progress? = @monitor.synchronize { @live && !@realtime.nil? }

        def unsubscribe_progress
          subscription = @monitor.synchronize { @progress }
          subscription&.unsubscribe
        rescue StandardError => error
          @logger&.info("host.progress_unsubscribe_failed", host: public_id,
                        error_class: error.class.name)
        end

        # ONE FRAME OFF THE HOST'S PROGRESS FEED: into the ring under the
        # daemon's next sequence, and to every listener — never through
        # `apply`: a frame says nothing about a task's status, so it nudges
        # no gate and moves no position. A frame naming a loop this follower
        # is not backed by is not this host's news.
        def apply_progress(frame)
          loop_id = frame.agent_loop_public_id
          payload = @monitor.synchronize do
            next if loop_id && @loop && loop_id != @loop && !@loops.include?(loop_id)
            turn = frame.payload["turn_public_id"]
            next if turn && (turn == @last_deleted_turn || (turn == @turn && !current_turn_visible?))

            entry = { "seq" => (@frame_sequence += 1) }.merge(frame.to_h.transform_keys(&:to_s))
            @frames << entry
            @frames.shift while @frames.length > FRAMES_KEPT
            entry
          end
          return if payload.nil?

          notify(Frame.new("progress", payload))
        end

        # `ConnectionLostError` carries no retry hint; a rate limit does.
        def transient_wait(error)
          error.retry_after || POLL_SECONDS
        end

        def reset_streams(preserve_settled: false)
          held = @monitor.synchronize do
            # A durable sealed reply does not become incomplete when a tail
            # subscription opens after it. New executions clear this marker.
            next false if preserve_settled && transcript_body_final?

            held = !@text.empty? || !@reasoning.empty?
            @text.reset
            @reasoning.reset
            held
          end
          notify(Frame.new("stream_reset", { "reason" => "reopened" })) if held
        end

        def unsubscribe_transcript
          subscription = @monitor.synchronize { @transcript }
          subscription&.unsubscribe
        rescue StandardError => error
          # Ending a stream that is already gone is not a failure of the
          # thing that asked for it.
          @logger&.info("host.transcript_unsubscribe_failed", host: public_id,
                        error_class: error.class.name)
        end

        # ONE ITEM OFF THE HOST'S TRANSCRIPT FEED, deliberately NOT routed
        # through `apply`: a delta says nothing about a task, so it never
        # nudges the --until gate and never touches the events
        # feed's position. What it does is accumulate, and fan to whoever is
        # watching.
        #
        # A settle is translated into the two frames a printer already
        # understands — a `stream_reset` when the sealed body did not
        # continue what was streamed, then a `text_delta` carrying the
        # REMAINDER — so no `text_settled` type is invented and the SSE
        # vocabulary stays the kernel's.
        #
        # A settled `round` or `call` is RELAYED WHOLE as a frame of its own
        # type: its `text_preview` is truncated
        # by construction, so it never touches the accumulator — replacing a
        # full preview with it would silently shorten what a person is
        # reading — but it is the thread's row, and `rho transcript --follow`
        # folds it through the SDK's `ThreadAccumulator` on the far side of
        # the daemon's SSE, where the credential never travels. The spine
        # law is the accumulator's, not this relay's.
        def apply_transcript(item)
          return if orphan?(item)

          case item.type
          when "text_delta" then stream_delta(@text, item, "text_delta")
          when "reasoning_delta" then stream_delta(@reasoning, item, "reasoning_delta")
          when "stream_reset" then reset_streams(preserve_settled: true)
          when "turn" then settle_transcript(item)
          when "round", "call" then notify(Frame.new(item.type, item.to_h.transform_keys(&:to_s)))
          else
            # Tool-call deltas are not text. Anything this daemon predates
            # means nothing here, the same tolerance `apply` keeps.
            nil
          end
        end

        # A delta cannot establish a turn or execution. An
        # item from another turn, candidate or loop is dropped. Only the
        # durable events feed establishes which execution the host follows;
        # a sealed body's rendered candidate may be a fallback to an older one.
        def orphan?(item)
          @monitor.synchronize do
            turn = item.turn_public_id
            next true if past_turn?(turn) || (turn && turn == @turn && !current_turn_visible?)
            next true if turn && @turn && turn != @turn

            variant = item.variant_public_id
            next true if variant && @variant && variant != @variant

            loop_id = item.agent_loop_public_id
            !!(loop_id && @loop && loop_id != @loop)
          end
        end

        # The stream a delta belongs to: the round's task key on a loop
        # round, the variant on a direct reply. A key that differs from the
        # one held is a NEW answer, and the accumulator starts over for it.
        def stream_key(item) = item.task_key || item.variant_public_id

        def stream_delta(accumulator, item, type)
          appended = @monitor.synchronize do
            next if transcript_body_final?

            accumulator.accumulate(item.text, key: stream_key(item))
          end
          return if appended.nil?

          payload = { "text" => appended }
          payload["kind"] = item.payload["kind"] if type == "reasoning_delta"
          notify(Frame.new(type, payload))
        end

        # Under the monitor: a complete body is fixed while its replacement
        # frames are still being delivered. Readers only finish after the
        # last frame, but late deltas and resets must already leave it alone.
        def transcript_body_final?
          @transcript_settling == execution_identity ||
            (turn_settled? && @transcript_settled.include?(@turn))
        end

        # COMPLETION WINS, and the whole sealed body is the TURN's: the
        # settled row carries `active_variant.content` where a round carries
        # a preview.
        def settle_transcript(item)
          return unless item.turn_public_id && item.turn_public_id == @monitor.synchronize { @turn }

          settle_text(item.turn_public_id, item.turn&.text)
        end

        def settle_text(turn_public_id, text, expected_identity: nil)
          settling = nil
          remainder, replaced = @monitor.synchronize do
            return unless current_turn_visible?
            return if @transcript_settling == execution_identity
            if expected_identity
              return unless !@stopped && execution_identity == expected_identity &&
                turn_settled? && !transcript_settled?
            end

            settling = @transcript_settling = execution_identity
            [@text.replace_on_settle(text), @text.replaced?]
          end
          frames = []
          frames << Frame.new("stream_reset", { "reason" => "replaced" }) if replaced
          frames << Frame.new("text_delta", { "text" => remainder }) unless remainder.empty?
          notify(frames.first) if frames.length > 1
          # RECORDED BEFORE THE LAST FRAME, never after and never before the
          # first: a reader ends on this, so the frame carrying the last word
          # has to be the one that closes it — and recording it before a
          # `stream_reset` would end a reader with the whole replacement unsent.
          @monitor.synchronize do
            # A replacement reset can notify a slow listener before the
            # remainder. Never seal a newer execution after that yield.
            return unless @transcript_settling.equal?(settling) && execution_identity == settling
            return if @stopped || !current_turn_visible?
            return if expected_identity && !turn_settled?

            @transcript_settled << turn_public_id
          end
          notify(frames.last) unless frames.empty?
        ensure
          # A yielding listener can begin another settle for the same execution.
          # Only the invocation that still owns this marker may clear it.
          @monitor.synchronize { @transcript_settling = nil if @transcript_settling.equal?(settling) }
        end
    end
  end
end
