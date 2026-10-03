module Conversations
  module Compaction
    # THE DELEGATE-EXPIRY FALLBACK: a compaction delegated to the agent's own tool
    # that NOBODY answered — the row expired at its park, `timed_out` or
    # `uncertain`, resolved by the summarizer's own `absorb` policy — leaves the
    # loop still owing a summary. The kernel appends its own summarizer ONCE in the
    # delegate's place, on either host: mid-turn a branch root the repaired round
    # waits on again, re-marked to read it; between turns the summary loop's new
    # deliverable. The expired row itself carries the fence, so a second expiry
    # (the kernel's step is a model task, never a delegate) finds nothing and the
    # round fails on size — the honest failure. A delegate that ANSWERED `failed`
    # is the agent's log to read, not the kernel's to paper over, and gets no
    # fallback. Asked at the one quiescence site, under the loop lock; narrated
    # `context_compacted` with `trigger: fallback` and what it fell from.
    class Fallback
      DELEGATE_FALLBACK = "delegate_fallback".freeze
      EXPIRED_STATUSES = %w[timed_out uncertain].freeze
      ABSORB = "absorb".freeze

      def self.call(agent_loop) = new(agent_loop).call

      def initialize(agent_loop)
        @agent_loop = agent_loop
      end

      # True when the kernel summarizer was appended: the loop is not done.
      def call
        return false unless @agent_loop.graph_mutable?

        delegate, round = expired_delegate
        return false if delegate.nil?

        round ? repair_round(delegate, round) : repair_summary_loop(delegate)
      end

      private

        # The one expired, unanswered, unrepaired delegate and the round that
        # named it — nil for a summary loop's own seed. An ordinary wake has
        # no candidates, so it never loads the loop's completed history.
        def expired_delegate
          nodes = @agent_loop.agent_loop_nodes
            .where(type: AgentLoopNodes::ToolTask.sti_name, status: EXPIRED_STATUSES, on_failure: ABSORB)
            .where("NOT (COALESCE(compaction, '{}'::jsonb) ? :key)", key: DELEGATE_FALLBACK).to_a
          return nil if nodes.empty?

          source = AgentLoopNodes::ModelTask::SUMMARY_SOURCE
          rounds = @agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name)
            .where("compaction ->> :source IN (:keys)", source: source, keys: nodes.map(&:node_key))
            .index_by { |round| round.compaction.fetch(source) }
          nodes.each do |node|
            round = rounds[node.node_key]
            return [node, round] if round
            return [node, nil] if summary_seed?(node)
          end
          nil
        end

        # Between turns the delegate is the whole seed of a `compaction_summary`
        # turn's loop — its deliverable, with no round to mark.
        def summary_seed?(node)
          @agent_loop.deliverable_node_id == node.id && @agent_loop.conversation_turn&.compaction_summary? == true
        end

        # ── Mid-turn: a branch root under the round, the round re-marked ──

        def repair_round(delegate, round)
          history = Serialize.loop_history(round)
          older, tail = Serialize.call(history.entries)
          return false if older.blank? && tail.blank?

          key = free_key
          step = summarizer(key, model: "#{round.provider_id}/#{round.model_ref}",
            reasoning_effort: round.reasoning_effort, tools: round.tool_definitions,
            profile: @agent_loop.declaring_profile).step(history.entries, older, tail)
          appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
            agent_loop: @agent_loop, steps: [step],
            origin: "kernel", expansion_parent: round,
            tip: AgentLoops::Tasks::Tip.seed(AgentLoops::Tasks::Compile::BRANCH, lifetime: round.lifetime),
            head: round.node_key, splice_reads: false
          ))
          return refused(appended, delegate) unless appended.applied?

          mark(round, round.compaction.to_h.merge(AgentLoopNodes::ModelTask::SUMMARY_SOURCE => key))
          fence(delegate, key)
          # The round's own grain, and the turn it backs when it backs one
          # (`Arm#narrate_round`'s shape): the item a conversation's feed
          # carries names the turn beside the loop.
          narrate(delegate, key, task_key: round.node_key, turn: @agent_loop.conversation_turn)
          scheduled
        end

        # ── Between turns: the summary loop's new deliverable ────────────

        def repair_summary_loop(delegate)
          conversation = @agent_loop.conversation
          entries = Serialize.timeline_entries(conversation)
          older, tail = Serialize.call(entries)
          return false if older.blank? && tail.blank?

          variant = @agent_loop.conversation_turn_variant
          key = free_key
          # The summary loop's own declaration: its turn carries the
          # conversation's default answerer, so this reads what the arm
          # declared — never another agent's turn's.
          profile = @agent_loop.declaring_profile
          step = summarizer(key, model: "#{variant.provider_id}/#{variant.model_ref}",
            reasoning_effort: variant.reasoning_effort,
            tools: profile&.tool_definitions, profile: profile).step(entries, older, tail)
          # Born ready: the expired delegate's absorbed settlement counts
          # resolved. Replace its queued readers as well as its deliverable,
          # so a follower reads the summary rather than the timeout.
          appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
            agent_loop: @agent_loop, steps: [step],
            origin: "kernel", replaces: delegate.node_key, expansion_parent: delegate,
            tip: AgentLoops::Tasks::Tip.new(
              spine: nil, waits: [AgentLoops::Tasks::Known.of(delegate)], reads: [],
              mark: AgentLoops::Tasks::Compile::BRANCH, detached: false, lifetime: delegate.lifetime
            )
          ))
          return refused(appended, delegate) unless appended.applied?

          fence(delegate, key)
          turn = @agent_loop.conversation_turn
          narrate(delegate, key, turn: turn, summary_turn: turn)
          scheduled
        end

        # The kernel's own step, on the host's own model and told the host's
        # declared set and its profile's `summarizer` slot; the policy is
        # the kernel's, so `Summarizer#step` takes the summarized branch.
        def summarizer(key, model:, reasoning_effort:, tools:, profile:)
          Summarizer.new(
            key: key, policy: { "mode" => Arm::MODE_KERNEL }, account: @agent_loop.account,
            model: model, reasoning_effort: reasoning_effort, address: nil, tools: tools, profile: profile
          )
        end

        # The fence, on the expired row itself — one column, both hosts,
        # read by `expired_delegate` above. `compaction` is attr_readonly for every
        # other writer; the kernel's repair writes past the guard.
        def fence(delegate, key) = mark(delegate, { DELEGATE_FALLBACK => key })

        def mark(node, compaction)
          AgentLoopNode.where(id: node.id).update_all(compaction: compaction, updated_at: Time.current)
        end

        def narrate(delegate, key, **grain)
          AgentLoop::Narration.record(@agent_loop, [CompactedEvent.item(
            agent_loop: @agent_loop, mode: Arm::MODE_KERNEL,
            trigger: Trigger.fallback(delegate).kind, summary_task_key: key,
            "fallback_from" => delegate.node_key, "fallback_reason" => delegate.error_key, **grain
          )])
        end

        # After commit (`perform_later` defers itself), never under the lock:
        # the new step is minted by a scheduler pass (the arm's own rule).
        def scheduled
          AgentLoops::ScheduleJob.perform_later(@agent_loop.id)
          true
        end

        def free_key
          used = @agent_loop.agent_loop_nodes.pluck(:node_key).to_set
          number = 1
          number += 1 while used.include?("#{Arm::KEY_PREFIX}#{number}")
          "#{Arm::KEY_PREFIX}#{number}"
        end

        # A fallback the door refused is logged and marked, so the loop is
        # not asked again on every pass; the round then fails on size.
        def refused(result, delegate)
          Rails.logger.error(
            "event=agent_loop_compaction_fallback_refused loop=#{@agent_loop.public_id} " \
            "delegate=#{delegate.node_key} " \
            "reason=#{result.errors.first&.fetch("code", nil) || result.outcome}"
          )
          fence(delegate, nil)
          false
        end
    end
  end
end
