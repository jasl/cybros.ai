module Conversations
  module Turns
    # Level-triggered, both frontiers: every reply invocation that
    # terminalized without its timeline knowing, and every loop-backed (loop,
    # variant) pair whose rows disagree — settle, reopen, or stop the loop a
    # successor replaced. Conversation lock first, then the loop or the
    # invocation; a held tail can settle directly after a fast retry.
    class Converge
      class << self
        def call(conversation_id: nil, agent_loop_id: nil, invocation_id: nil, batch: 200, cursors: {})
          new(conversation_id, agent_loop_id, invocation_id, batch, cursors).call
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

      def initialize(conversation_id, agent_loop_id, invocation_id, batch, cursors)
        @conversation_id = conversation_id
        @agent_loop_id = agent_loop_id
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

        if @agent_loop_id
          recorded = converge_loop(nil, @agent_loop_id, @conversation_id) ? 1 : 0
          return Outcome.accepted(Sweeps::Pass.new(counts: { scanned: 1, recorded: recorded }, more: false))
        end

        replies = window(reply_frontier, "reply", :id, :conversation_id, :public_id)
        loops = loop_frontier
        recorded = replies.count { |invocation_id, conversation_id, public_id| record(invocation_id, conversation_id, public_id) }
        recorded += loops.count { |arm, agent_loop_id, conversation_id| converge_loop(arm, agent_loop_id, conversation_id) }

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
          candidates = ConversationTurnVariant.where(
            status: ConversationTurnVariant::ACTIVE_STATUSES + ["failed"], deleted_at: nil
          )
          variants = window(candidates, "settle", :id)
          live = AgentLoop.where(status: AgentLoop::STATUSES - AgentLoop::TERMINAL_STATUSES)
          reopening = window(live, "reopen", :id)
          replaced = window(live, "replace", :id)

          settle = matching_pairs(ConversationTurnVariant.settling_from_loop.joins(:conversation_turn), variants)
            .map { |ids| [:settle, *ids] }
          reopen = matching_pairs(AgentLoop.reopening, reopening)
            .map { |ids| [:reopen, *ids] }
          replace = matching_pairs(AgentLoop.behind_a_successor, replaced)
            .map { |ids| [:replace, *ids] }
          settle + reopen + replace
        end

        def matching_pairs(scope, ids)
          return [] if ids.empty?

          # LIMIT 1 keeps each probe correlated to its already-materialized
          # id. An IN list alone lets the planner start at every variant's
          # status again, even when the source window has only 200 rows.
          probe = scope.where("#{scope.quoted_table_name}.id = frontier.id")
            .select("agent_loops.id AS agent_loop_id", "conversation_turns.conversation_id").limit(1)
          sql = ApplicationRecord.sanitize_sql_array([<<~SQL, ids])
            SELECT matched.agent_loop_id, matched.conversation_id
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

            settle_reply(conversation, invocation, ConversationTurnVariant.find_by(model_invocation_id: invocation.id))
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
        def converge_loop(arm, agent_loop_id, conversation_id)
          agent_loop_public_id = nil
          ApplicationRecord.transaction(requires_new: true) do
            conversation = Conversation.lock.find_by(id: conversation_id)
            agent_loop = AgentLoop.lock.find_by(id: agent_loop_id)
            next false if conversation.nil? || agent_loop.nil?
            agent_loop_public_id = agent_loop.public_id
            # A precise wake names one loop; the durable pair, re-read under
            # both locks, decides which (if any) transition is still owed.
            arm = if arm
              arm if still_on?(arm, agent_loop)
            else
              %i[settle reopen replace].find { |candidate| still_on?(candidate, agent_loop) }
            end
            next false if arm.nil?

            variant = agent_loop.conversation_turn_variant
            case arm
            when :settle then settle(conversation, agent_loop, variant)
            when :reopen then reopen(conversation, agent_loop, variant)
            else replace(agent_loop)
            end
            true
          end
        rescue StandardError => error
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "conversation_turn_converge_failed", agent_loop_public_id: agent_loop_public_id, arm: arm })
          false
        end

        def still_on?(arm, agent_loop)
          case arm
          when :settle
            ConversationTurnVariant.settling_from_loop.exists?(id: agent_loop.conversation_turn_variant_id)
          when :reopen then AgentLoop.reopening.exists?(id: agent_loop.id)
          else AgentLoop.behind_a_successor.exists?(id: agent_loop.id)
          end
        end

        # SETTLE: the loop's turn shape lands on the pair; a completed
        # loop's answer is the deliverable's output, entry-copied. Release
        # steers accepted after the loop finished but before this turn settled;
        # a delivered reply also closes its binding while background work runs.
        def settle(conversation, agent_loop, variant)
          shape = summary_shape(agent_loop, variant)
          adopt_deliverable(agent_loop, variant) if shape.status == "completed"
          RetainedSteers.archive(agent_loop) if agent_loop.delivered? || agent_loop.terminal?
          variant.settle(status: shape.status)
          turn = variant.conversation_turn.reload
          if agent_loop.delivered? || agent_loop.terminal?
            Inputs::ReleaseSteers.call(host: conversation, inputs: turn.steering_inputs)
          end
          narrate_settle(conversation, agent_loop, turn, variant, shape)
          Conversations::TranscriptStream.settled_turn(turn, variant: variant, agent_loop: agent_loop)
          # The lane is idle again; queued arrivals continue.
          Inputs::DrainJob.perform_later(conversation.id)
          relay_kick(conversation)
        end

        # The task's execution and the summary's usability are distinct:
        # an answered delegate keeps its completed/error facts, but an
        # error or empty summary cannot replace the conversation's history.
        # Settle the kernel's turn as failed so the waiting input drains
        # against the intact history, without inventing a delegate retry.
        def summary_shape(agent_loop, variant)
          shape = agent_loop.turn_shape
          if ConversationTurnVariant::ACTIVE_STATUSES.include?(variant.status) &&
              (AgentLoops::SourceWork.stopped_source?(agent_loop) || (agent_loop.stopped? && shape.status == "completed"))
            return AgentLoop::TurnShape.new(status: "canceled", failure_reason_key: "source_stopped")
          end
          return shape unless shape.status == "completed" && variant.conversation_turn.compaction_summary?
          return shape if agent_loop.deliverable&.usable_summary?

          AgentLoop::TurnShape.new(status: "failed", failure_reason_key: "deliverable_unresolved")
        end

        # REOPEN: the regenerate edge the tail already admits — the turn
        # runs again behind the loop a person retried or answered.
        def reopen(conversation, agent_loop, variant)
          variant.settle(status: "running")
          turn = variant.conversation_turn.reload
          narrate_settle(conversation, agent_loop, turn, variant, agent_loop.turn_shape)
        end

        # REPLACE: the one site of `replaced`. The stop writes
        # `canceling`; the drain lands `canceled` and releases the steers.
        def replace(agent_loop)
          AgentLoops::Stop.terminate(agent_loop, failure_reason: "replaced")
          AgentLoops::ConvergeTerminalStepsJob.perform_later
          AgentLoops::ScheduleJob.perform_later(agent_loop.id)
        end

        def adopt_deliverable(agent_loop, variant)
          output = agent_loop.deliverable&.content_bodies&.find_by(role: "output")
          return if output.nil?

          clone = ContentBodies::CloneSealed.call(source: output, owner: variant, role: "content")
          variant.update_content_preview(clone.effective_text)
        end

        # `status` is the TURN's row after the write: what a follower
        # renders, never a shape the row could contradict. A hold names
        # the newest failure and the keys an adjudicator can act on.
        # `turn_kind` is the row's kind, on every `turn_status` a
        # conversation host narrates (agent_loops/transition.rb says why).
        def narrate_settle(conversation, agent_loop, turn, variant, shape)
          payload = {
            "turn_public_id" => turn.public_id,
            "turn_kind" => turn.kind,
            "variant_public_id" => variant.public_id,
            "agent_loop_public_id" => agent_loop.public_id,
            "status" => turn.status,
            "variant_status" => variant.status,
            "failure_reason_key" => shape.failure_reason_key,
          }
          if agent_loop.needs_attention?
            payload["error_key"] = AgentLoops::Transition.newest_blocking_error_key(agent_loop)
            payload["blocked_task_keys"] = AgentLoops::Transition.blocked_task_keys(agent_loop)
          end
          ConversationEvent::Append.call(
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
          if AgentLoops::SourceWork.stopped_variant_source?(variant)
            variant.update!(status: "canceled")
            return settle_sample(conversation, invocation, variant.conversation_turn, variant, source_stopped: true)
          end
          adopt_answer(invocation, variant)
          turn = variant.conversation_turn
          variant.update!(status: invocation.work_status)
          change = switch_to_fallback(conversation, invocation, turn, variant) if fallback
          if change
            narrate(conversation, invocation, turn, variant, "running", model_change: change)
          else
            settle_sample(conversation, invocation, turn, variant)
          end
        end

        # THE DIRECT LANE'S SWITCH, decided here once under the conversation
        # lock, before anything reads the reply as settled: the sample was
        # `running` until now, so no follower sees a `failed` that is then
        # retracted. A classifier's refusal — never a content block — or the
        # provider's overload on every attempt re-asks once on the answering
        # profile's `fallback_model`, read live; a fallback sample never
        # falls back again, and no model that already declined this turn or
        # was overloaded for it is picked. A refused guard or resolver, and a
        # fallback that cannot take the history's tool rounds, is the stand.
        # Answers the narrated `model_change`, or nil.
        def switch_to_fallback(conversation, invocation, turn, variant)
          return unless (invocation.refused? || invocation.overloaded?) && !variant.fallback?

          candidate = AgentLoops::ModelFallback.candidate(
            answerer: turn.answering_user, current: variant, trigger: :switch,
            reason: AgentLoops::ModelFallback.reason_of(invocation),
            category: invocation.refusal_category, excluded: switched_models(turn)
          )
          return if candidate.nil?
          return unless takes_history?(conversation, invocation, candidate)

          regenerated = Regenerate.fallback(conversation: conversation, turn: turn, origin: variant,
            candidate: candidate, principal: invocation.creating_user)
          return unless regenerated.accepted?

          previous = "#{invocation.provider_id}/#{invocation.model_ref}"
          AgentLoops::ModelFallback.log_switch("conversation=#{conversation.public_id} turn=#{turn.public_id}",
            previous, candidate)
          candidate.narration(previous).fetch("model_change")
        end

        # A fallback that needs every tool round's reasoning back stands on a
        # history of tool rounds it did not produce (ModelFallback's gate).
        def takes_history?(conversation, invocation, candidate)
          resolved = AgentLoops::ModelFallback.resolve(account: conversation.account, workload: "text_generation",
            candidate: candidate, configuration: AgentLoops::ModelFallback.chosen_configuration(invocation))
          return true unless resolved.resolved?

          AgentLoops::ModelFallback.takes_tool_history?(resolved.selection,
            invocation.content_bodies.find_by(role: "request"))
        end

        # Every model a classifier refused on this turn or the provider was
        # overloaded for, whoever asked — the whole deck, not the sample's
        # origin chain: a person's regenerate takes the ACTIVE sample as its
        # origin, so a chain walk would miss the failed sibling of an earlier
        # regenerate.
        def switched_models(turn)
          deck = ModelInvocation.where(id: turn.conversation_turn_variants.select(:model_invocation_id))
          deck.where(finish_quality: SimpleInference::FinishQuality::REFUSED)
            .or(deck.where(failure_reason_key: AgentLoops::ModelFallback::OVERLOADED))
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
              model: "#{variant.provider_id}/#{variant.model_ref}", reasoning_effort: variant.reasoning_effort
            ),
            configuration: OneShots::CoerceConfiguration.call({}),
            port: ModelSelection::Resolver.new
          )
          armed = if selection.resolved?
            Compaction::Arm.call(conversation: conversation, selection: selection.selection,
              trigger: Compaction::Trigger.overflow(variant), raw: variant.context_mode == "raw")
          end
          return if armed&.accepted?

          Rails.logger.info(
            "event=reply_overflow_unarmed conversation=#{conversation.public_id} " \
            "turn=#{variant.conversation_turn.public_id} reason=#{armed&.outcome || selection.refusal}"
          )
        end

        # A spawned child's settled reply is its parent's: the relay is
        # level-triggered over `relayed_at`, so this is a latency hint
        # after commit — never the relay itself, which takes the parent's
        # locks this transaction must not hold under the child's.
        def relay_kick(conversation)
          AgentLoops::Spawn::RelayJob.perform_later(conversation.id) if conversation.spawned? || conversation.scheduled_execution?
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
          ConversationEvent::Append.call(
            host: conversation,
            idempotency_key: invocation.public_id,
            items: [{
              type: "turn_status",
              payload: {
                "turn_public_id" => turn.public_id,
                "turn_kind" => turn.kind,
                "variant_public_id" => variant.public_id,
                "status" => turn_status,
                "variant_status" => invocation.work_status,
                "failure_reason_key" =>
                  (invocation.declined? ? ModelInvocation::DECLINED_KEY : invocation.failure_reason_key),
                "finish_quality" => invocation.finish_quality,
                "refusal_category" => invocation.refusal_category,
                "model_change" => model_change,
              }.compact,
            }]
          )
        end
    end
  end
end
