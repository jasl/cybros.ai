module Conversations
  module Turns
    # Level-triggered, both frontiers: every reply invocation that
    # terminalized without its timeline knowing, and every loop-backed (loop,
    # variant) pair whose rows disagree — settle, reopen, or stop the loop a
    # successor replaced. Conversation lock first, then the loop or the
    # invocation; a held tail can settle directly after a fast retry.
    class Converge
      class << self
        def call(conversation_id: nil, run_id: nil, invocation_id: nil, batch: 200, cursors: {})
          new(conversation_id, run_id, invocation_id, batch, cursors).call
        end

        # A STOP IN THE WINDOW (`Turns::Cancel`): a declined or overloaded
        # reply no converger has recorded yet settles on the spot, under the
        # caller's conversation and invocation locks, with no switch — a
        # stop is never lost to a fallback nobody asked for, and the stamp
        # keeps the converger from deciding it again.
        def settle_now(conversation, invocation, variant)
          new(conversation.id, nil, invocation.id, 0, {}).settle_reply(conversation, invocation, variant, fallback: false)
        end
      end

      def initialize(conversation_id, run_id, invocation_id, batch, cursors)
        @conversation_id = conversation_id
        @run_id = run_id
        @invocation_id = invocation_id
        @batch = batch
        @cursors = cursors
        @next_cursors = {}
        @scanned = 0
      end

      def call
        if @invocation_id
          replies = reply_frontier.where(id: @invocation_id).pluck(:id, :conversation_id, :public_id)
          recorded = replies.count { |ids| record(*ids) }
          return Outcome.accepted(Sweeps::Pass.new(counts: { scanned: replies.length, recorded: recorded }, more: false))
        end

        if @run_id
          recorded = converge_loop(nil, @run_id, @conversation_id) ? 1 : 0
          return Outcome.accepted(Sweeps::Pass.new(counts: { scanned: 1, recorded: recorded }, more: false))
        end

        replies = window(reply_frontier, "reply", :id, :conversation_id, :public_id)
        loops = loop_frontier
        recorded = replies.count { |invocation_id, conversation_id, public_id| record(invocation_id, conversation_id, public_id) }
        recorded += loops.count { |arm, run_id, conversation_id| converge_loop(arm, run_id, conversation_id) }

        Outcome.accepted(Sweeps::Pass.new(
          counts: { scanned: @scanned, recorded: recorded },
          cursor: @next_cursors,
          more: @batch.positive? && @next_cursors.values.any?
        ))
      end

      # A reply's terminal applied to its timeline, and the stamp that takes
      # it off the frontier, in the caller's transaction.
      def settle_reply(conversation, invocation, variant, fallback: true)
        apply(conversation, invocation, variant, fallback: fallback) if variant
        invocation.update!(terminal_event_recorded_at: DatabaseClock.now)
      end

      private

        def reply_frontier
          ModelInvocation
            .where(status: ModelInvocation::TERMINAL_STATUSES)
            .where(terminal_event_recorded_at: nil)
            .where.not(conversation_id: nil)
        end

        # Materialize indexed source windows BEFORE the joined predicates.
        # Healthy and failing pairs both cost budget and advance their phase;
        # a partial window parks until the next recurring wake.
        def loop_frontier
          candidates = Variant.where(
            status: Variant::ACTIVE_STATUSES + ["failed"], deleted_at: nil
          )
          variants = window(candidates, "settle", :id)
          live = Run.where(status: Run::STATUSES - Run::TERMINAL_STATUSES)
          reopening = window(live, "reopen", :id)
          replaced = window(live, "replace", :id)

          settle = matching_pairs(Variant.settling_from_loop.joins(:turn), variants)
            .map { |ids| [:settle, *ids] }
          reopen = matching_pairs(Run.reopening, reopening)
            .map { |ids| [:reopen, *ids] }
          replace = matching_pairs(Run.behind_a_successor, replaced)
            .map { |ids| [:replace, *ids] }
          settle + reopen + replace
        end

        def matching_pairs(scope, ids)
          return [] if ids.empty?

          # LIMIT 1 keeps each probe correlated to its already-materialized
          # id. An IN list alone lets the planner start at every variant's
          # status again, even when the source window has only 200 rows.
          probe = scope.where("#{scope.quoted_table_name}.id = frontier.id")
            .select("runs.id AS run_id", "turns.conversation_id").limit(1)
          sql = ApplicationRecord.sanitize_sql_array([<<~SQL, ids])
            SELECT matched.run_id, matched.conversation_id
            FROM unnest(ARRAY[?]::bigint[]) AS frontier(id)
            CROSS JOIN LATERAL (#{probe.to_sql}) AS matched
          SQL
          ApplicationRecord.lease_connection.select_rows(sql)
        end

        def window(scope, phase, key, *columns)
          after = @cursors.fetch(phase, 0)
          @next_cursors[phase] = after
          return [] if after.nil? || !@batch.positive?

          rows = scope.where(key => (after + 1)..).order(key).limit(@batch).pluck(key, *columns)
          last_key = columns.empty? ? rows.last : rows.last&.first
          @scanned += rows.length
          @next_cursors[phase] = rows.length == @batch ? last_key : nil
          rows
        end

        def record(invocation_id, conversation_id, invocation_public_id)
          ApplicationRecord.transaction(requires_new: true) do
            conversation = Conversation.lock.find_by(id: conversation_id)
            invocation = ModelInvocation.lock.find_by(id: invocation_id)
            next false if conversation.nil? || invocation.nil?
            next false unless invocation.terminal? && invocation.terminal_event_recorded_at.nil?

            settle_reply(conversation, invocation, Variant.find_by(model_invocation_id: invocation.id))
            true
          end
        rescue StandardError => error
          # The poison-row lesson: one unconvergeable row must not abort the
          # batch. It stays on the frontier and the floor retries it.
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "conversation_reply_converge_failed", invocation_public_id: invocation_public_id })
          false
        end

        # Conversation, then loop; the arm is re-read under both locks
        # from the same scopes, so a pair that moved meanwhile is simply
        # not the one the frontier saw.
        def converge_loop(arm, run_id, conversation_id)
          run_public_id = nil
          ApplicationRecord.transaction(requires_new: true) do
            conversation = Conversation.lock.find_by(id: conversation_id)
            run = Run.lock.find_by(id: run_id)
            next false if conversation.nil? || run.nil?
            run_public_id = run.public_id
            # A precise wake names one loop; the durable pair, re-read under
            # both locks, decides which (if any) transition is still owed.
            arm = if arm
              arm if still_on?(arm, run)
            else
              %i[settle reopen replace].find { |candidate| still_on?(candidate, run) }
            end
            next false if arm.nil?

            variant = run.variant
            case arm
            when :settle
              next false unless settle(conversation, run, variant)
            when :reopen then reopen(conversation, run, variant)
            else replace(run)
            end
            true
          end
        rescue StandardError => error
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "turn_converge_failed", run_public_id: run_public_id, arm: arm })
          false
        end

        def still_on?(arm, run)
          case arm
          when :settle
            Variant.settling_from_loop.exists?(id: run.variant_id)
          when :reopen then Run.reopening.exists?(id: run.id)
          else Run.behind_a_successor.exists?(id: run.id)
          end
        end

        # SETTLE: the loop's turn shape lands on the pair; a completed
        # loop's answer is the deliverable's output, entry-copied. Release
        # steers accepted after the loop finished but before this turn settled;
        # a delivered reply also closes its binding while background work runs.
        def settle(conversation, run, variant)
          shape = summary_shape(run, variant)
          changed = shape.status != variant.status
          adopt_deliverable(run, variant) if changed && shape.status == "completed"
          RetainedSteers.archive(run) if run.delivered? || run.terminal?
          variant.settle(status: shape.status) if changed
          turn = variant.turn.reload
          if run.delivered? || run.terminal?
            Inputs::ReleaseSteers.call(host: conversation, inputs: turn.steering_inputs)
          end
          if changed
            narrate_settle(conversation, run, turn, variant, shape)
            Conversations::TranscriptStream.settled_turn(turn, variant: variant, run: run)
            # The lane is idle again; queued arrivals continue.
            Inputs::DrainJob.perform_later(conversation.id)
            relay_kick(conversation)
            true
          else
            # A fast retry can end with another unusable summary before REOPEN:
            # the failed turn already matches, but its old cost hold no longer
            # blocks the queue. Recover that wake without repeating settlement.
            wake_waiting_input(conversation)
            false
          end
        end

        def wake_waiting_input(conversation)
          state = conversation.inputs.where(state: %w[pending blocked])
            .merge(Input.due(DatabaseClock.now)).in_read_order.pick(:state)
          Inputs::DrainJob.perform_later(conversation.id) if state == "pending"
        end

        # The task's execution and the summary's usability are distinct:
        # an answered delegate keeps its completed/error facts, but an
        # error or empty summary cannot replace the conversation's history.
        # Settle the kernel's turn as failed so the waiting input drains
        # against the intact history, without inventing a delegate retry.
        def summary_shape(run, variant)
          shape = run.turn_shape
          if Variant::ACTIVE_STATUSES.include?(variant.status) &&
              (Runs::SourceWork.stopped_source?(run) || (run.stopped? && shape.status == "completed"))
            return Run::TurnShape.new(status: "canceled", failure_reason_key: "source_stopped")
          end
          return shape unless shape.status == "completed" && variant.turn.compaction_summary?
          return shape if run.deliverable&.usable_summary?

          Run::TurnShape.new(status: "failed", failure_reason_key: "deliverable_unresolved")
        end

        # REOPEN: the regenerate edge the tail already admits — the turn
        # runs again behind the loop a person retried or answered.
        def reopen(conversation, run, variant)
          variant.settle(status: "running")
          turn = variant.turn.reload
          narrate_settle(conversation, run, turn, variant, run.turn_shape)
        end

        # REPLACE: the one site of `replaced`. The stop writes
        # `canceling`; the drain lands `canceled` and releases the steers.
        def replace(run)
          Runs::Stop.terminate(run, failure_reason: "replaced")
          Runs::ConvergeTerminalStepsJob.perform_later
          Runs::ScheduleJob.perform_later(run.id)
        end

        def adopt_deliverable(run, variant)
          output = run.deliverable&.content_bodies&.find_by(role: "output")
          return if output.nil?

          clone = ContentBodies::CloneSealed.call(source: output, owner: variant, role: "content")
          variant.update_content_preview(clone.effective_text)
        end

        # `status` is the TURN's row after the write: what a follower
        # renders, never a shape the row could contradict. A hold names
        # the newest failure and the keys an adjudicator can act on.
        # `turn_kind` is the row's kind, on every `turn_status` a
        # conversation host narrates (runs/transition.rb says why).
        def narrate_settle(conversation, run, turn, variant, shape)
          payload = {
            "turn_public_id" => turn.public_id,
            "turn_kind" => turn.kind,
            "variant_public_id" => variant.public_id,
            "run_public_id" => run.public_id,
            "status" => turn.status,
            "variant_status" => variant.status,
            "failure_reason_key" => shape.failure_reason_key,
          }
          if run.needs_attention?
            payload["error_key"] = Runs::Transition.newest_blocking_error_key(run)
            payload["blocked_task_keys"] = Runs::Transition.blocked_task_keys(run)
          end
          Event::Append.call(
            host: conversation,
            items: [{ type: "turn_status", payload: payload.compact }]
          )
        end

        # The sample's status is the WORK's (`work_status`): a declined
        # answer completed the call and failed the reply, so it is a failed
        # sample at every read below — never the rendered one, never a
        # context bump, never `completed` in the narration. A declined
        # sample the answerer's fallback re-asks leaves the turn exactly as
        # it was — running, its lane taken, its steers bound, no snapshot:
        # it never went idle.
        def apply(conversation, invocation, variant, fallback:)
          if Runs::SourceWork.stopped_variant_source?(variant)
            variant.update!(status: "canceled")
            return settle_sample(conversation, invocation, variant.turn, variant, source_stopped: true)
          end
          @model_skips = nil
          adopt_answer(invocation, variant)
          turn = variant.turn
          variant.update!(status: invocation.work_status)
          change = switch_to_fallback(conversation, invocation, turn, variant) if fallback
          if change
            narrate(conversation, invocation, turn, variant, "running", model_change: change)
          else
            settle_sample(conversation, invocation, turn, variant)
          end
        end

        # Decide recovery under the conversation lock before publishing a
        # terminal turn. Each variant retains the accepted policy and input;
        # its recovery chain prevents returning to a spent route. A person's
        # independent regeneration starts another execution on the same turn.
        def switch_to_fallback(conversation, invocation, turn, variant)
          return unless invocation.recovery_eligible?

          resolved = Runs::ModelFallback.recover(account: conversation.account, workload: "text_generation",
            current: invocation, owner: variant, configuration: Runs::ModelFallback.chosen_configuration(invocation),
            excluded: switched_models(variant), request_body: invocation.content_bodies.find_by(role: "request")) do |selection|
            Regenerate.fallback_refusal(conversation: conversation, turn: turn, origin: variant,
              selection: selection, principal: invocation.creating_user)
          end
          @model_skips = resolved.skips
          return unless resolved.resolved?

          candidate = Runs::ModelFallback.from_selection(resolved.selection,
            reason: Runs::ModelFallback.reason_of(invocation), category: invocation.refusal_category)
          regenerated = Regenerate.fallback(conversation: conversation, turn: turn, origin: variant,
            candidate: candidate, principal: invocation.creating_user)
          return unless regenerated.accepted?

          previous = "#{invocation.provider_id}/#{invocation.model_ref}"
          Runs::ModelFallback.log_switch("conversation=#{conversation.public_id} turn=#{turn.public_id}",
            previous, candidate)
          candidate.narration(previous).fetch("model_change")
        end

        def switched_models(variant)
          ModelInvocation.where(id: variant.execution_chain.filter_map(&:model_invocation_id))
            .pluck(:provider_id, :model_ref).map { |provider_id, model_ref| "#{provider_id}/#{model_ref}" }
        end

        def settle_sample(conversation, invocation, turn, variant, source_stopped: false)
          status = variant.status
          # A completed sample becomes the rendered one; a failed one never
          # drags a settled turn down — it just sits in the deck.
          if status == "completed"
            turn.update!(status: "completed", active_variant: variant)
            turn_status = "completed"
          else
            kept = turn.active_variant_id &&
              turn.active_variant_id != variant.id &&
              turn.active_variant.completed?
            turn_status = kept ? "completed" : status
            turn.update!(status: turn_status)
          end

          updates = { last_activity_at: Time.current }
          updates[:active_turn_id] = nil if conversation.active_turn_id == turn.id
          if status == "completed" && turn.visibility == "visible"
            updates[:context_revision] = conversation.context_revision + 1
          end
          conversation.update!(updates)

          # The steer's target has settled: its binding is over, so the row
          # falls back to the queue instead of charging the caller's bound
          # forever (the third steering strand).
          Inputs::ReleaseSteers.call(host: conversation, inputs: turn.steering_inputs)
          narrate(conversation, invocation, turn, variant, turn_status)
          # What the turn settled as, under the deltas' turn id, so a
          # follower replaces its accumulator with the row.
          Conversations::TranscriptStream.settled_turn(turn.reload, variant: variant)
          if !source_stopped && !conversation.reasoning_replay_downgraded_at && invocation.replay_refused?
            conversation.downgrade_reasoning_replay(turn: turn)
          end
          arm_overflow(conversation, invocation, variant) if !source_stopped && invocation.context_overflow?
          # The lane is idle again; queued arrivals continue.
          Inputs::DrainJob.perform_later(conversation.id)
          relay_kick(conversation)
        end

        # A WINDOW OVERFLOW IS COMPACTION'S: the provider refused the reply
        # for its length, so the between-turn summary is armed here, under
        # the conversation lock, on the reply's own model — the reply stays a
        # failed sample and the next head drains behind the summary. A lane
        # whose policy is `off`, or a timeline already summarized, arms
        # nothing and says why.
        def arm_overflow(conversation, invocation, variant)
          selection = ModelSelection.resolve(
            account: conversation.account, workload: "text_generation",
            submitted: Nexus::SubmittedModelSelection.new(
              model: "#{variant.provider_id}/#{variant.model_ref}", reasoning_effort: variant.reasoning_effort,
              reasoning_enabled: variant.reasoning_enabled
            ),
            configuration: InferenceRequests::CoerceConfiguration.call({}),
            port: ModelSelection::Resolver.new
          )
          armed = if selection.resolved?
            Compaction::Arm.call(conversation: conversation, selection: selection.selection,
              trigger: Compaction::Trigger.overflow(variant), raw: variant.context_mode == "raw")
          end
          return if armed&.accepted?

          Rails.logger.info(
            "event=reply_overflow_unarmed conversation=#{conversation.public_id} " \
            "turn=#{variant.turn.public_id} reason=#{armed&.outcome || selection.refusal}"
          )
        end

        # A spawned child's settled reply is its parent's: the relay is
        # level-triggered over `relayed_at`, so this is a latency hint
        # after commit — never the relay itself, which takes the parent's
        # locks this transaction must not hold under the child's.
        def relay_kick(conversation)
          Runs::Spawn::RelayJob.perform_later(conversation.id) if conversation.spawned? || conversation.scheduled_execution?
        end

        # The answer moves the way every content move in this plane moves:
        # entry-copy onto the SAME fragments. The invocation keeps its own
        # sealed evidence; the variant owns the timeline's copy.
        def adopt_answer(invocation, variant)
          response = invocation.content_bodies.find_by(role: "response")
          if response
            ContentBodies::CloneSealed.call(source: response, owner: variant, role: "content")
            variant.update_content_preview(response.effective_text)
          end
          reasoning = invocation.content_bodies.find_by(role: "reasoning")
          if reasoning
            ContentBodies::CloneSealed.call(source: reasoning, owner: variant, role: "reasoning")
          end
          # Assembly reads traces per turn, and a settled variant is the
          # turn's durable face; a failed run never converges, so a partial trace never replays.
          trace = invocation.content_bodies.find_by(role: "reasoning_trace")
          if trace
            ContentBodies::CloneSealed.call(source: trace, owner: variant, role: "reasoning_trace")
          end
        end

        # `status` is the turn's settled state and `variant_status` the
        # sample's, so a client never renders a turn state the row contradicts.
        # A declined sample names the refusal as its reason, its category
        # beside the quality, and — when the answerer's fallback re-asks it
        # — the switch, the turn still `running`.
        def narrate(conversation, invocation, turn, variant, turn_status, model_change: nil)
          Event::Append.call(
            host: conversation,
            idempotency_key: invocation.public_id,
            items: [{
              type: "turn_status",
              payload: {
                "turn_public_id" => turn.public_id,
                "turn_kind" => turn.kind,
                "variant_public_id" => variant.public_id,
                "status" => turn_status,
                "variant_status" => variant.status,
                "failure_reason_key" =>
                  (invocation.declined? ? ModelInvocation::DECLINED_KEY : invocation.failure_reason_key),
                "finish_quality" => invocation.finish_quality,
                "refusal_category" => invocation.refusal_category,
                "model_change" => model_change,
                "model_skips" => @model_skips.presence,
              }.compact,
            }]
          )
        end
    end
  end
end
