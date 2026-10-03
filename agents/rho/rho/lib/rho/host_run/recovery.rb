module Rho
  class HostRun
    # Hosted events expire independently of their host. A completed replay
    # recovers a missing prefix from the existing durable read surfaces, on
    # the same consumer that applies events. Its position never invents a
    # consumed event: restored_sequence only avoids repeating the same read.
    module Recovery
      private

        # The final transcript frame can disappear while durable events are
        # already caught up. Read that turn's deck on the existing probe;
        # a later execution or a live settle can supersede the HTTP response.
        def recover_transcript
          identity = @monitor.synchronize do
            execution_identity if !@stopped && turn_settled? && !transcript_settled?
          end
          return if identity.nil?

          turn, variant, = identity
          restored = restored_turn_variant(turn, variant_public_id: variant)
          return if restored.nil?

          settle_text(turn, restored.content, expected_identity: identity)
        end

        def recover_replay(head)
          return if @stopped

          needed = @monitor.synchronize do
            # A fork copies a local answer before allocating its first event.
            # Its initial empty replay still needs one durable state read.
            initial_empty = @restored_sequence.nil? && @feed.position.sequence.zero?
            mark_replay_gap if initial_empty || (head && head > replayed_sequence)
            @replay_truncated
          end
          return unless needed

          recovered = restore_history(@replay_turn)
          return if @stopped

          settled = @monitor.synchronize do
            @restored_sequence = [@restored_sequence || 0, head || 0].max
            changed = turn_settled? && @settled_before_replay != execution_identity
            @replay_truncated = false
            @replay_turn = nil
            @settled_before_replay = nil
            changed
          end
          settle_execution if recovered && settled
        end

        # These helpers run under the projection monitor. The first missing
        # event captures the previously settled identity before its suffix
        # can move the projection; retries keep that same comparison.
        def mark_replay_gap
          return if @replay_truncated

          @settled_before_replay = execution_identity if turn_settled?
          @replay_truncated = true
          @replay_turn = nil
        end

        def replayed_sequence = [@feed.position.sequence, @restored_sequence || 0].max

        def execution_identity = [@turn, @variant, @loop]

        def restore_history(known_turn)
          return restore_standalone unless @host.outlives_turn?

          current_turn = @context.fetch.active_turn_public_id
          turn = recovery_turn(current_turn || known_turn)
          turn_id = current_turn || turn&.public_id || known_turn
          return clear_recovered_execution if turn_id.nil?

          variant = recovery_variant(turn_id, turn&.status)
          return clear_recovered_execution if variant.nil?

          loop_row = recovery_loop(variant.agent_loop_public_id)
          status = turn&.status || loop_row&.turn&.status
          return false if status.nil?

          moved = @monitor.synchronize do
            next false if @stopped

            previous = [@turn, @loop]
            reset_execution
            @turn = turn_id
            @turn_kind = turn&.kind
            # Hidden turns remain controllable when explicitly listed for
            # recovery; their bodies must stay hidden in the projection.
            @turn_visibility = turn&.visibility || "hidden"
            @turn_concealed = false
            @variant = variant.public_id
            @loop = loop_row&.public_id
            @loops << @loop if @loop && !@loops.include?(@loop)
            @status = status
            @complete = TURN_TERMINAL_STATUSES.include?(@status)
            @failure_reason_key = loop_row&.turn&.failure_reason_key
            restore_loop_projection(loop_row) if loop_row
            previous != [@turn, @loop]
          end
          return false if @stopped

          settle_text(turn_id, turn.active_variant&.content) if turn && @complete
          @on_turn&.call(self) if moved
          true
        end

        # Removal can outlive its event. With no readable execution left,
        # clear the old projection without inventing a terminal or ending
        # the conversation. Late frames from that old turn remain stale.
        def clear_recovered_execution
          changed, had_text = @monitor.synchronize do
            next [false, false] if @stopped

            changed = @turn || @loop
            had_text = !@text.empty? || !@reasoning.empty?
            if @turn
              remove_turn_frames(@turn)
              @turns_seen << @turn unless @turns_seen.include?(@turn)
            end
            reset_execution
            @turn = nil
            @turn_kind = nil
            [changed, had_text]
          end
          @gate&.cancel! if changed
          notify(Frame.new("stream_reset", { "reason" => "replaced" })) if had_text
          @on_turn&.call(self) if changed
          false
        end

        def restore_standalone
          loop_row = @context.fetch
          @monitor.synchronize do
            return false if @stopped

            reset_execution
            @loop = loop_row.public_id
            @status = loop_row.turn.status
            @failure_reason_key = loop_row.turn.failure_reason_key
            @complete = TURN_TERMINAL_STATUSES.include?(@status)
            restore_loop_projection(loop_row)
          end
          true
        end

        # Prefer the current execution, then the one identified by replay.
        # With neither identity, take the newest readable reply. Recovery does
        # not mark a turn seen: events arriving during these reads still have
        # to move the one consumer through their original order.
        def recovery_turn(known)
          before = 2_147_483_647
          loop do
            page = @context.turns.list(before_position: before, limit: 100, include_hidden: true)
            found = page.items.reverse.find do |turn|
              known ? turn.public_id == known : !turn.inherited? && turn.kind != "message"
            end
            return found if found || page.items.length < 100

            before = page.before_position
          end
        end

        def recovery_variant(turn_id, status)
          deck = @context.turns.variants(turn_id)
          return deck.active if TURN_TERMINAL_STATUSES.include?(status)

          deck.items.reverse.find { |variant| !TURN_TERMINAL_STATUSES.include?(variant.status) } || deck.active
        rescue CybrosAgent::Api::NotFound
          # A deleted or concealed turn is not a deleted host.
          nil
        end

        def recovery_loop(public_id)
          @loop_context.call(public_id).fetch if public_id && @loop_context
        rescue CybrosAgent::Api::NotFound
          # A retained answer can outlive the execution trace behind it.
          # Both reads use the conversation's access level; a missing trace
          # has no live execution left for this follower to control.
          nil
        end
    end
  end
end
