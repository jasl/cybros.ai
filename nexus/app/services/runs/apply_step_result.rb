module Runs
  # Applies one terminal step invocation to its node under the loop and
  # invocation locks; the generation-keyed `internal_creation_key` fences a
  # stale result so only the live generation's answer counts.
  class ApplyStepResult
    KEY_PATTERN = /\Atask:(\d+):(\d+)\z/

    class << self
      def call(run:, invocation:)
        node, generation = locate(run, invocation)
        return if node.nil?
        return unless node.status == "running"
        return unless node.selected_model_invocation_id == invocation.id
        return unless node.execution_generation == generation

        case invocation.status
        when "completed"
          # A forced stop can win after the provider has finished but before
          # its files become public task output. Keep that publication cut at
          # the Run lock; graceful draining still accepts completed work.
          if node.image_generation? && run.stopped?
            cancel(run, node, invocation)
          elsif invocation.declined?
            refuse(run, node, invocation)
          elsif invocation.finish_error?
            fail_generation(run, node, invocation)
          else
            complete(node, invocation)
          end
        when "canceled"
          if invocation.availability_skipped? && !run.canceling? && !abandoned_now?(run, node)
            dispatch_failure(run, node, invocation)
          elsif invocation.failure_reason_key == "interrupted" &&
              !run.canceling? && !abandoned_now?(run, node)
            # A forced pause is not a failure: fresh generation, no retry
            # spent, resume re-mints it. During a stop's drain the cancel
            # branch wins, or a requeue strands a waiting task in a dead loop.
            requeue(node)
          else
            cancel(run, node, invocation)
          end
        else dispatch_failure(run, node, invocation)
        end
        # The round's own narration: what the step answered and what it
        # cost, keyed by the invocation so a re-converged terminal replays
        # rather than duplicates.
        Transition.round(node.reload, invocation)
      end

      private

        def locate(run, invocation)
          match = KEY_PATTERN.match(invocation.internal_creation_key.to_s)
          return [nil, nil] if match.nil?

          node = run.tasks.find_by(id: Integer(match[1], 10))
          [node, Integer(match[2], 10)]
        end

        def complete(node, invocation)
          response = invocation.content_bodies.find_by(role: "response")
          if node.image_generation?
            Images::Publish.call(node, invocation)
          elsif response
            ContentBodies::CloneSealed.call(source: response, owner: node, role: "output")
            StampOutputPreview.call(node)
          end
          run = node.run
          # The round driver runs before the node completes, so a round that
          # cannot be authored can still fail the step that asked for it; the
          # release walk below settles the fan's countdowns.
          refusal = ExpandRound.call(run: run, node: node)
          if refusal
            FailNode.call(
              run: run, node: node, worklist: [],
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
        # refusal advances through the execution's captured fallback order; a content
        # block is never re-sent to anyone, and a step nothing waits for any
        # more is not re-run at all.
        def refuse(run, node, invocation)
          if run.canceling?
            cancel(run, node, invocation)
            return
          end

          verdict =
            if abandoned_now?(run, node) then ModelFallback::Verdict.new(stand: :abandoned)
            elsif invocation.blocked? then ModelFallback::Verdict.new(stand: :blocked)
            else ModelFallback.switch_for(run: run, node: node, invocation: invocation)
            end
          return if verdict.switched?

          FailNode.call(
            run: run, node: node, worklist: [],
            error_key: ModelInvocation::DECLINED_KEY,
            error_detail: RefusalSentence.for(invocation: invocation, verdict: verdict),
            output_summary: node.output_summary.merge(
              "finish_quality" => invocation.finish_quality, "refusal_category" => invocation.refusal_category
            ).compact
          )
        end

        # A provider's abnormal finish does not establish a transient fault
        # or a classifier refusal. Fail without spending retries or switching
        # models, and never expand the partial calls it may have streamed.
        def fail_generation(run, node, invocation)
          if run.canceling?
            cancel(run, node, invocation)
          else
            FailNode.call(
              run: run, node: node, worklist: [],
              error_key: invocation.failure_reason_key, error_detail: invocation.failure_detail,
              output_summary: node.output_summary.merge("finish_quality" => invocation.finish_quality)
            )
          end
        end

        # The cancel's own reason survives onto the task (`join_loser_canceled`);
        # `step_canceled` is only the fallback for a cancel that named none. A
        # person's branch cancel resolves as it settles.
        def cancel(run, node, invocation)
          reason = invocation.failure_reason_key.presence || "step_canceled"
          FailNode.call(
            run: run, node: node, worklist: [],
            status: "canceled", error_key: reason,
            failure_resolution: (CancelBranch::RESOLUTION if reason == CancelBranch::REASON)
          )
        end

        def dispatch_failure(run, node, invocation)
          # A canceling loop never requeues or holds: the step settles canceled
          # so the drain finds no live-looking work left behind.
          if run.canceling?
            cancel(run, node, invocation)
            return
          end

          # The third size arm: a lane with no token counter has only the
          # provider's refusal as a signal, so the repair sits above the retry
          # (retrying cannot make it fit) and after the canceling check.
          if repair_overflow(run, node, invocation)
            return
          end

          # Provider failures reach here after the invocation's own route
          # budget. A node retry cannot renew that budget or retry terminal
          # authentication/request errors.
          verdict = recovery_switch(run, node, invocation)
          return if verdict&.switched?


          status = invocation.timed_out? ? "timed_out" : "failed"
          detail = if verdict
            RefusalSentence.for(invocation: invocation, verdict: verdict)
          end
          FailNode.call(
            run: run, node: node, worklist: [],
            status: status,
            error_key: invocation.failure_reason_key.presence || "step_failed",
            error_detail: detail || invocation.failure_detail
          )
        end

        # Content blocks, Stop and terminal request errors never recover.
        def recovery_switch(run, node, invocation)
          return nil unless invocation.recovery_eligible? && !abandoned_now?(run, node)

          ModelFallback.switch_for(run: run, node: node, invocation: invocation)
        end

        # Precheck, requeue, arm: splice refuses a running head, so requeue
        # first — but only once Arm's pure-read preconditions pass, or the node
        # sits queued forever. A repair is not a failed attempt, so no retry is charged.
        def repair_overflow(run, node, invocation)
          return false unless invocation.context_overflow?
          return false if abandoned_now?(run, node)
          return false unless Conversations::Compaction::Arm.armable?(node)

          requeue(node)
          return true if Conversations::Compaction::Arm.call(
            run: run, node: node, trigger: Conversations::Compaction::Trigger.overflow(node)
          )

          # Only an Append refusal reaches here: the node is queued unrepaired
          # and the pre-send arms get their own try at the same wall.
          true
        end

        # Pause and context repair requeue the node under a fresh generation;
        # neither consumes or renews the provider attempt allowance.
        def requeue(node)
          Transition.node(
            node,
            execution_generation: node.execution_generation + 1,
            status: "queued",
            started_at: nil
          )
        end

        # A requeue of a node nothing waits for would re-mint a branch every
        # consumer of which is dead. The deliverable is always waited for and a
        # sink has no consumers to have lost.
        def abandoned_now?(run, node)
          return false if run.deliverable_node_id == node.id

          consumers = node.outgoing_edges.includes(:to_node).map(&:to_node)
          consumers.any? && consumers.all?(&:terminal?)
        end
    end
  end
end
