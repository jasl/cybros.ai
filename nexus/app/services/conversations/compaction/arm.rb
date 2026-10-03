module Conversations
  module Compaction
    # A context that will not fit is a context to make fit: ONE arm over
    # two hosts. Mid-turn the host is the round's backing loop — the arm
    # chooses ONCE per wall between clearing older tool results (the prune
    # arm, a mark and no new row) and one summarizer task appended through
    # the one door that the round reads in place of its history. Between
    # turns the host is a `compaction_summary` turn created running and
    # BACKED BY A ONE-TASK KERNEL LOOP whose seed is that same summarizer:
    # the converger settles the turn and adopts the summary, and the head
    # waits behind it. The kernel picks no threshold, only "will not go";
    # this is the one licensed cache bust, once per wall.
    class Arm
      SUMMARY_KIND = "compaction_summary".freeze
      # A summary rides the user channel: on the lanes that hoist `system`
      # into the top-level block it would carry the operator's authority.
      SUMMARY_ROLE = "user".freeze

      MODE_KERNEL = "kernel".freeze
      MODE_OFF = "off".freeze
      MODE_PRUNE = "prune".freeze
      KEY_PREFIX = "k".freeze
      RAW_REFUSAL = :compaction_unavailable_under_raw

      # What the mid-turn host answered with: the mode it chose and, for
      # a summarizing repair, the summarizer's key — the caller splices
      # THAT node into the drain it is walking; a prune re-schedules the
      # round itself, which now composes from rows.
      Repair = Data.define(:mode, :summary_task_key) do
        def pruned? = mode == MODE_PRUNE
      end

      class << self
        # A pure read, so the post-send arm can requeue only when the
        # repair is possible rather than leave a node queued forever.
        def armable?(node) = refusal_for_round(node).nil?

        # The mid-turn preconditions, by name — one vocabulary for the
        # scheduler, the manual door and the provider's refusal. The
        # rendering is the expensive question and comes last.
        def refusal_for_round(node)
          policy_refusal(node) || (:nothing_to_compact if Serialize.loop_entries(node).empty?)
        end

        # The cheap half, from the row alone: the policy's word, the marks
        # (armed once), and the raw-input rule — under raw the kernel owns
        # no history, so its own mode refuses and only a delegate arms.
        def policy_refusal(node)
          policy = node.compaction || {}
          return :compaction_disabled if policy["mode"] == MODE_OFF
          return :already_compacted if node.repaired?

          RAW_REFUSAL if refused_under_raw?(policy, node.agent_loop.raw?)
        end

        def refused_under_raw?(policy, raw) = raw && policy["mode"] != Summarizer::MODE_DELEGATE

        # THE DELEGATE-EXPIRY FALLBACK, asked at the one quiescence site: a
        # delegate nobody answered expired at its park, so the kernel's own
        # summarizer runs once in its place. Answers true when it appended
        # one — the loop is not quiescent.
        def fallback(agent_loop) = Fallback.call(agent_loop)

        # Pure reads, asked first: on an empty conversation "nothing to
        # compact" is the useful answer, not `model_selection_missing`.
        def refusal_for(conversation)
          return :already_compacted if new(conversation: conversation).send(:already_compacted?)

          :nothing_to_compact if Serialize.timeline_entries(conversation).empty?
        end

        # The host names the arm: `agent_loop:`/`node:` is the mid-turn
        # host and answers a Repair when armed, falsy when the round must
        # fail; `conversation:`/`selection:` is the between-turn host and
        # answers an Outcome — the turn it armed, or why not. The policy is
        # the round's mid-turn and the trigger's author's declaration
        # between turns: one policy, whichever host reads it. `raw` is the
        # head input's word between turns (the summary loop is not born yet).
        def call(trigger:, raw: false, **host)
          if host.key?(:node)
            node = host.fetch(:node)
            return false if policy_refusal(node)

            policy = node.compaction || {}
            new(trigger: trigger, agent_loop: host.fetch(:agent_loop), node: node, policy: policy).arm_round
          else
            policy = trigger.authoring_user&.compaction_policy || {}
            return Outcome.refused(RAW_REFUSAL) if refused_under_raw?(policy, raw)

            new(trigger: trigger, policy: policy, **host).arm_between_turns
          end
        end
      end

      def initialize(trigger: nil, agent_loop: nil, node: nil, policy: nil, conversation: nil, selection: nil)
        @trigger = trigger
        @agent_loop = agent_loop
        @node = node
        @policy = policy
        @conversation = conversation
        @selection = selection
      end

      # ── Mid-turn: the round's backing loop ─────────────────────────────

      def arm_round
        history = Serialize.loop_history(@node)
        older, tail = Serialize.call(history.entries)
        return false if older.blank? && tail.blank?
        if AgentLoops::LifecycleHooks.before_compact(@agent_loop, @node, trigger: @trigger)
          hook = @agent_loop.agent_loop_nodes.where(lifecycle_event: "pre_compact")
            .where("tool_input ->> 'task_key' = ?", @node.node_key).first!
          return Repair.new(mode: "hook", summary_task_key: hook.node_key)
        end
        return prune(history) if prune?(history)

        @key = free_key
        # A branch-marked root the round waits on; the edge only — the
        # composer finds the summary through the mark, and one dead read
        # entry pushed a maximal fan past the bound.
        result = AgentLoops::Tasks::Append.call_locked(AgentLoops::Tasks::Append::Command.kernel(
          agent_loop: @agent_loop, steps: [summarizer.step(history.entries, older, tail)],
          origin: "kernel", expansion_parent: @node,
          tip: AgentLoops::Tasks::Tip.seed(AgentLoops::Tasks::Compile::BRANCH, lifetime: @node.lifetime),
          head: @node.node_key, splice_reads: false
        ))
        return refused(result) unless result.applied?

        mark(AgentLoopNodes::ModelTask::SUMMARY_SOURCE => @key)
        narrate_round(mode, summary_task_key: @key)
        Repair.new(mode: mode, summary_task_key: @key)
      end

      # ── Between turns: a `compaction_summary` turn behind a one-task loop ──

      def arm_between_turns
        # Armed at most once per wall: a second wall at a summary means the
        # summary itself does not fit or the last repair failed, and either
        # would arm forever. `off` is the author's posture on this host too.
        return Outcome.refused(:already_compacted) if already_compacted?
        return Outcome.refused(:compaction_disabled) if @policy["mode"] == MODE_OFF

        entries = Serialize.timeline_entries(@conversation)
        older, tail = Serialize.call(entries)
        return Outcome.refused(:nothing_to_compact) if older.blank? && tail.blank?

        # The savepoint is load-bearing: inside the drain's open
        # transaction a half-written arm would commit a `running` summary
        # turn nothing settles, and the lane would be busy forever. A rolled-back savepoint answers nil.
        ApplicationRecord.transaction(requires_new: true) do
          create_summary_turn(entries, older, tail)
        end || Outcome.refused(:arm_failed)
      rescue StandardError => error
        # A repair that cannot even be armed must not take the reply down
        # with it: the caller blocks the head honestly on the size wall
        # that started this, which is an outcome a client can act on.
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "conversation_compaction_arm_failed", conversation: @conversation.public_id })
        Outcome.refused(:arm_failed)
      end

      private

        # THE CHOICE, ONCE PER WALL: the cheaper repair while the results outside the
        # keep-recent tail cover the overshoot — net of the placeholder each cleared call
        # leaves — and the summarizer once they cannot; a trigger with no number (the
        # provider's refusal, a person) summarizes. Results are prunable and the model's own
        # bytes (answers, arguments) are not, so the floor only climbs between summaries.
        # Never prune-then-summarize: the mark decides.
        def prune?(history)
          overshoot = @trigger.overshoot
          return false unless overshoot && history.prunable_bytes >= overshoot.bytes
          return true if overshoot.tokens.nil?

          # The ordinary scheduling path already resolved this model. A hook
          # may resume later, so read the node's current selection at this rare
          # boundary. Without a usable counter, byte savings prove no token gain.
          resolved = ModelSelection.resolve(
            account: @agent_loop.account, workload: "text_generation",
            submitted: Nexus::SubmittedModelSelection.new(model: host_model, reasoning_effort: host_effort),
            configuration: OneShots::CoerceConfiguration.call(@node.request_options),
            port: ModelSelection::Resolver.new
          )
          return false unless resolved.resolved?

          profile = resolved.selection.execution_profile
          return false if profile.token_counter.nil?

          freed = history.prunable_tokens(profile)
          freed && freed >= overshoot.tokens
        end

        # No new row: the mark names the first retained round (the repaired
        # round itself when nothing joins the tail), the round composes
        # from rows on its next start, and nothing is appended — the
        # caller re-schedules the round in the pass it is walking.
        def prune(history)
          mark(AgentLoopNodes::ModelTask::PRUNED_BEFORE => (history.prune_round || @node).node_key)
          narrate_round(MODE_PRUNE)
          Repair.new(mode: MODE_PRUNE, summary_task_key: nil)
        end

        # The mark says both "read this instead of the history" and "do
        # not arm twice". `compaction` is attr_readonly for every other
        # writer; the kernel's repair writes past the guard rather than removing it.
        def mark(fields)
          AgentLoopNode.where(id: @node.id).update_all(
            compaction: @policy.merge(fields), updated_at: Time.current
          )
        end

        def mode = @policy["mode"].presence || MODE_KERNEL

        # ONE `context_compacted` (CompactedEvent) for both hosts. The
        # mid-turn half narrates through the loop's buffer, the between-turn
        # half through the conversation's own append — both reach the host's
        # plane.
        def compacted_payload(agent_loop, mode, **grain)
          CompactedEvent.payload(agent_loop: agent_loop, mode: mode, trigger: @trigger.kind, **grain)
        end

        def narrate_round(mode, summary_task_key: nil)
          AgentLoop::Narration.record(@agent_loop, [{
            type: CompactedEvent::TYPE,
            payload: compacted_payload(@agent_loop, mode, turn: @agent_loop.conversation_turn,
              task_key: @node.node_key, summary_task_key: summary_task_key),
          }])
        end

        # The one task shape for both hosts, built from what the host
        # knows: its own model, the address a delegate summarizes, the key,
        # and the declaring profile whose `summarizer` slot the kernel's
        # step reads.
        def summarizer
          Summarizer.new(
            key: @key, policy: @policy, account: (@conversation || @agent_loop).account,
            model: host_model, reasoning_effort: host_effort, address: address, selection: @selection,
            tools: declared_tools, profile: declaring_profile
          )
        end

        # The set the model saw: the repaired round's mid-turn; the
        # answering agent's standing declaration between turns, and a
        # human-answered conversation declares nothing.
        def declared_tools
          return @node.tool_definitions if @node

          declaring_profile&.tool_definitions
        end

        # The loop's answering agent mid-turn, the conversation's DEFAULT
        # answerer between turns — the profile whose tools the summarizer
        # is told and whose slot it reads; nil for a human.
        def declaring_profile
          @node ? @agent_loop.declaring_profile : @conversation.declaring_profile
        end

        # The host's own model: the round's mid-turn, the selection's
        # between turns (the manual door names a cheaper one).
        def host_model
          return "#{@node.provider_id}/#{@node.model_ref}" if @node

          "#{@selection.provider_id}/#{@selection.model_ref}"
        end

        def host_effort = @node ? @node.reasoning_effort : @selection.reasoning.effort

        # The model-facing address of what a delegate summarizes: the
        # timeline and its turn, plus the round mid-turn; a standalone
        # loop is its own host and names itself. Between turns the summary
        # loop is not yet born when the step is authored, and the turn is
        # the row that outlives it.
        def address
          return { "conversation" => @conversation.public_id, "turn" => @turn.public_id } unless @node

          turn = @agent_loop.conversation_turn
          host = if turn
            { "conversation" => @agent_loop.conversation.public_id, "turn" => turn.public_id }
          else
            { "agent_loop" => @agent_loop.public_id }
          end
          host.merge("task" => @node.node_key)
        end

        def refused(result)
          Rails.logger.error(
            "event=agent_loop_compaction_refused loop=#{@agent_loop.public_id} " \
            "task=#{@node.node_key} " \
            "reason=#{result.errors.first&.fetch("code", nil) || result.outcome}"
          )
          nil
        end

        # The first free `k` key on the host loop; a newborn loop's is `k1`.
        def free_key
          used = @agent_loop ? @agent_loop.agent_loop_nodes.pluck(:node_key).to_set : Set.new
          number = 1
          number += 1 while used.include?("#{KEY_PREFIX}#{number}")
          "#{KEY_PREFIX}#{number}"
        end

        # One indexed row, not the timeline. Status-blind, unlike the
        # assembly cut: a running summary is in flight and a failed one
        # would arm forever, so both refuse.
        def already_compacted?
          newest = @conversation.timeline.entries(
            surface: :assembly,
            before_position: @conversation.timeline_position_head,
            limit: 1
          ).last
          newest&.turn&.kind == SUMMARY_KIND
        end

        # The host row and its loop-backed variant, then the loop through
        # the seam's one writer with the summarizer as its whole seed —
        # the deliverable by construction (the tip after the one step).
        # The scheduler mints the step after commit, as it does round one
        # of a reply; nothing is admitted from here.
        def create_summary_turn(entries, older, tail)
          position = @conversation.timeline_position_head
          @turn = ConversationTurn.create!(
            account: @conversation.account,
            conversation: @conversation,
            position: position,
            kind: SUMMARY_KIND,
            role: SUMMARY_ROLE,
            status: "running",
            speaker_actor: Actors::Resolve.system(account: @conversation.account),
            control_owner_user: @trigger.authoring_user,
            # The DEFAULT answerer at this moment: the summary loop derives
            # from this column what `declared_tools` read; never the
            # trigger's addressee.
            answering_user: @conversation.answering_user,
            visibility: "visible",
            origin: @trigger.origin,
          )
          variant = ConversationTurnVariant.create!(
            account: @conversation.account,
            conversation_turn: @turn,
            position: 0,
            status: "running",
            source: "agent_loop",
            provider_id: @selection.provider_id,
            model_ref: @selection.model_ref,
            reasoning_effort: @selection.reasoning.effort,
          )
          @key = free_key
          # A summary normally has no approval policy. Configured lifecycle
          # tools retain the declaring profile's rules at this boundary too.
          hooked = declaring_profile&.lifecycle_hooks.present?
          born = Turns::BackingLoop.create(
            conversation: @conversation, variant: variant, creating_user: @trigger.authoring_user,
            steps: [summarizer.step(entries, older, tail)],
            tip: AgentLoops::Tasks::Tip.seed(AgentLoops::Tasks::Compile::BRANCH),
            approval_mode: hooked ? declaring_profile.approval_mode : "bypass",
            approval_rules: hooked ? declaring_profile.approval_rules : nil
          )
          # A refused seed leaves a turn and a variant behind, so the
          # savepoint has to go with the refusal rather than the refusal
          # being returned past it.
          raise ActiveRecord::Rollback unless born.accepted?

          agent_loop = born.value
          @turn.update!(active_variant: variant)
          @conversation.update!(
            timeline_position_head: position + 1,
            active_turn: @turn,
            last_activity_at: Time.current,
          )
          narrate_turn(@turn, agent_loop)
          # After commit (`perform_later` defers itself), never under the lock:
          # round one of the summary loop is minted by a scheduler pass.
          AgentLoops::ScheduleJob.perform_later(agent_loop.id)
          Outcome.accepted(@turn)
        end

        def narrate_turn(turn, agent_loop)
          ConversationEvent::Append.call(
            host: @conversation,
            idempotency_key: turn.public_id,
            items: [
              {
                type: "turn_created",
                payload: {
                  "turn_public_id" => turn.public_id,
                  "position" => turn.position,
                  "kind" => turn.kind,
                  "role" => turn.role,
                  "status" => turn.status,
                  "visibility" => turn.visibility,
                  "answering_user_public_id" => turn.answering_user.public_id,
                },
              },
              {
                type: CompactedEvent::TYPE,
                payload: compacted_payload(agent_loop, mode, turn: turn, summary_turn: turn),
              },
            ]
          )
        end
    end
  end
end
