module AgentRuns
  # Applies one terminal step invocation to its node under the loop and
  # invocation locks; the generation-keyed `internal_creation_key` fences a
  # stale result so only the live generation's answer counts.
  class ApplyStepResult
    KEY_PATTERN = /\Aagent_run_task:(\d+):(\d+)\z/

    class << self
      def call(agent_run:, invocation:)
        node, generation = locate(agent_run, invocation)
        return if node.nil?
        return unless node.status == "running"
        return unless node.selected_model_invocation_id == invocation.id
        return unless node.execution_generation == generation

        case invocation.status
        when "completed"
          if invocation.declined?
            refuse(agent_run, node, invocation)
          elsif invocation.finish_error?
            fail_generation(agent_run, node, invocation)
          else
            complete(node, invocation)
          end
        when "canceled"
          if invocation.failure_reason_key == "interrupted" &&
              !agent_run.canceling? && !abandoned_now?(agent_run, node)
            # A forced pause is not a failure: fresh generation, no retry
            # spent, resume re-mints it. During a stop's drain the cancel
            # branch wins, or a requeue strands a waiting task in a dead loop.
            requeue(node)
          else
            cancel(agent_run, node, invocation)
          end
        else dispatch_failure(agent_run, node, invocation)
        end
        # The round's own narration: what the step answered and what it
        # cost, keyed by the invocation so a re-converged terminal replays
        # rather than duplicates.
        Transition.round(node.reload, invocation)
      end

      private

        def locate(agent_run, invocation)
          match = KEY_PATTERN.match(invocation.internal_creation_key.to_s)
          return [nil, nil] if match.nil?

          node = agent_run.agent_run_tasks.find_by(id: Integer(match[1], 10))
          [node, Integer(match[2], 10)]
        end

        def complete(node, invocation)
          response = invocation.content_bodies.find_by(role: "response")
          if response
            ContentBodies::CloneSealed.call(source: response, owner: node, role: "output")
            StampOutputPreview.call(node)
          end
          agent_run = node.agent_run
          # The round driver runs before the node completes, so a round that
          # cannot be authored can still fail the step that asked for it; the
          # release walk below settles the fan's countdowns.
          refusal = ExpandRound.call(agent_run: agent_run, node: node)
          if refusal
            FailNode.call(
              agent_run: agent_run, node: node, worklist: [],
              error_key: ExpandRound::EXPANSION_REFUSED, error_detail: refusal
            )
            return
          end

          # MERGED, never replaced: the summary may already say what this
          # execution replaced, and a caveat rides beside that fact.
          Transition.node(
            node,
            status: "completed",
            completed_at: Time.current,
            output_summary: node.output_summary.merge("finish_quality" => invocation.finish_quality).compact
          )
          Release.settled(node)
        end

        # A DECLINED ANSWER FAILS THE STEP over a completed invocation — the
        # call happened and was billed, the work has no answer. `complete`'s
        # other failure (`round_expansion_refused`) is the precedent for the
        # two axes disagreeing. The gates mirror `dispatch_failure`'s, minus
        # what a refusal must never do: re-send the same request to the same
        # model by the retry budget (a resend usually earns another refusal),
        # repair an overflow, or expand a round (a declined answer authored
        # no calls — ApplyResult stored none). Before it fails, a classifier's
        # refusal re-runs once on the answerer's declared fallback; a content
        # block is never re-sent to anyone, and a step nothing waits for any
        # more is not re-run at all.
        def refuse(agent_run, node, invocation)
          if agent_run.canceling?
            cancel(agent_run, node, invocation)
            return
          end

          verdict =
            if abandoned_now?(agent_run, node) then ModelFallback::Verdict.new(stand: :abandoned)
            elsif invocation.blocked? then ModelFallback::Verdict.new(stand: :blocked)
            else ModelFallback.switch_for(agent_run: agent_run, node: node, invocation: invocation)
            end
          return if verdict.switched?

          FailNode.call(
            agent_run: agent_run, node: node, worklist: [],
            error_key: ModelInvocation::DECLINED_KEY,
            error_detail: RefusalSentence.for(invocation: invocation, verdict: verdict,
              declaring_profile: agent_run.declaring_profile),
            output_summary: node.output_summary.merge(
              "finish_quality" => invocation.finish_quality, "refusal_category" => invocation.refusal_category
            ).compact
          )
        end

        # A provider's abnormal finish does not establish a transient fault
        # or a classifier refusal. Fail without spending retries or switching
        # models, and never expand the partial calls it may have streamed.
        def fail_generation(agent_run, node, invocation)
          if agent_run.canceling?
            cancel(agent_run, node, invocation)
          else
            FailNode.call(
              agent_run: agent_run, node: node, worklist: [],
              error_key: invocation.failure_reason_key, error_detail: invocation.failure_detail,
              output_summary: node.output_summary.merge("finish_quality" => invocation.finish_quality)
            )
          end
        end

        # The cancel's own reason survives onto the task (`join_loser_canceled`);
        # `step_canceled` is only the fallback for a cancel that named none. A
        # person's branch cancel resolves as it settles.
        def cancel(agent_run, node, invocation)
          reason = invocation.failure_reason_key.presence || "step_canceled"
          FailNode.call(
            agent_run: agent_run, node: node, worklist: [],
            status: "canceled", error_key: reason,
            failure_resolution: (CancelBranch::RESOLUTION if reason == CancelBranch::REASON)
          )
        end

        def dispatch_failure(agent_run, node, invocation)
          # A canceling loop never requeues or holds: the step settles canceled
          # so the drain finds no live-looking work left behind.
          if agent_run.canceling?
            cancel(agent_run, node, invocation)
            return
          end

          # The third size arm: a lane with no token counter has only the
          # provider's refusal as a signal, so the repair sits above the retry
          # (retrying cannot make it fit) and after the canceling check.
          if repair_overflow(agent_run, node, invocation)
            return
          end

          # The provider was overloaded on every attempt: the step re-runs
          # once on the answerer's declared fallback, as a refusal does. A
          # stand falls to the mail rung, then the retry budget, then the
          # failure that names why nothing re-ran it.
          verdict = overload_switch(agent_run, node, invocation)
          return if verdict&.switched?

          unless abandoned_now?(agent_run, node)
            return if ModelFallback.call(agent_run: agent_run, node: node, reason: invocation.failure_reason_key)
          end

          # Once the size repair is unavailable or spent, resending cannot change
          # what fits. This also stops an oversized summarizer after its first refusal.
          if !invocation.context_overflow? && node.auto_retries_used < node.retry_budget && !abandoned_now?(agent_run, node)
            requeue(node, count_retry: true)
            return
          end

          status = invocation.timed_out? ? "timed_out" : "failed"
          detail = if verdict
            RefusalSentence.for(invocation: invocation, verdict: verdict, declaring_profile: agent_run.declaring_profile)
          end
          FailNode.call(
            agent_run: agent_run, node: node, worklist: [],
            status: status,
            error_key: invocation.failure_reason_key.presence || "step_failed",
            error_detail: detail || invocation.failure_detail
          )
        end

        # The overload trigger: nil for any other failure, and for a step
        # nothing waits for any more — no sentence names a switch it never
        # considered.
        def overload_switch(agent_run, node, invocation)
          return nil unless invocation.overloaded? && !abandoned_now?(agent_run, node)

          ModelFallback.switch_for(agent_run: agent_run, node: node, invocation: invocation)
        end

        # Precheck, requeue, arm: splice refuses a running head, so requeue
        # first — but only once Arm's pure-read preconditions pass, or the node
        # sits queued forever. A repair is not a failed attempt, so no retry is charged.
        def repair_overflow(agent_run, node, invocation)
          return false unless invocation.context_overflow?
          return false if abandoned_now?(agent_run, node)
          return false unless Conversations::Compaction::Arm.armable?(node)

          requeue(node, count_retry: false)
          return true if Conversations::Compaction::Arm.call(
            agent_run: agent_run, node: node, trigger: Conversations::Compaction::Trigger.overflow(node)
          )

          # Only an Append refusal reaches here: the node is queued unrepaired
          # and the pre-send arms get their own try at the same wall.
          true
        end

        # ONE requeue writer: the fence always bumps; the auto-retry
        # counter moves only when a real failure is being retried — a
        # forced pause is not a failure and spends nothing.
        def requeue(node, count_retry: false)
          Transition.node(
            node,
            execution_generation: node.execution_generation + 1,
            auto_retries_used: node.auto_retries_used + (count_retry ? 1 : 0),
            status: "queued",
            started_at: nil
          )
        end

        # A requeue of a node nothing waits for would re-mint a branch every
        # consumer of which is dead. The deliverable is always waited for and a
        # sink has no consumers to have lost.
        def abandoned_now?(agent_run, node)
          return false if agent_run.deliverable_node_id == node.id

          consumers = node.outgoing_edges.includes(:to_node).map(&:to_node)
          consumers.any? && consumers.all?(&:terminal?)
        end
    end
  end
end
