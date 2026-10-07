module Conversations
  # Fork without copy: the child copies the closure capped at the new edge, adopts
  # the boundary turn as its own latest message (zero content bytes), and seeds a
  # sparse overlay. Under the source's row lock: the fork-vs-reap point. A side
  # shares settled history through the closure and owns a frozen reference to an
  # unfinished head. It never adopts that head's execution or reads its later work.
  class Fork
    # One refusal for every way a fork can be too big: closure depth and
    # overlay seed rows are the two dimensions that grow with history.
    MAX_DEPTH = 32
    MAX_OVERLAY_SEED = 5_000

    Command = Data.define(:conversation, :turn_public_id, :variant_public_id,
      :acting_user, :title, :side) do
      def initialize(side: false, **) = super
    end

    class << self
      def call(command)
        new(command).call
      end
    end

    def initialize(command)
      @command = command
    end

    def call
      unless @command.conversation.writable_by?(@command.acting_user)
        return Outcome.refused(:not_authorized)
      end

      @source = @command.conversation
      @source.with_lock do
        next Outcome.refused(:not_found) if @source.tombstoned?
        # Structural: a side is reference-only, and a fork of one — plain
        # or side — would inherit its boundary item.
        next Outcome.refused(:side_of_side) if @source.side?
        next side_fork if @command.side

        target = resolve_target
        next Outcome.refused(:not_found) if target.nil?

        chosen = resolve_variant(target)
        next Outcome.refused(:not_found) if chosen.nil? || chosen.deleted?
        next Outcome.refused(:variant_not_forkable) unless chosen.completed?

        closure = child_closure(target.position)
        next Outcome.refused(:fork_too_large) if closure.any? { |edge| edge[:depth] > MAX_DEPTH }

        seed = overlay_seed_rows(target.position, closure)
        next Outcome.refused(:fork_too_large) if seed.length > MAX_OVERLAY_SEED

        child = create_child(target, chosen)
        write_closure(child, closure)
        adopt_boundary(child, target, chosen)
        write_overlay(child, seed)
        copy_memory(child)
        copy_store_entries(child)
        copy_access_entries(child)
        narrate(child, target, chosen)
        Outcome.accepted(child)
      end
    rescue ActiveRecord::InvalidForeignKey
      # The source (or an ancestor) vanished under a concurrent reap that
      # committed before our lock: the conversation is gone, and gone reads
      # as absence — never a 500.
      Outcome.refused(:not_found)
    end

    private

      # A queued input is not a turn. The closure stops below unfinished work;
      # that work is captured into one local reference after the shared prefix.
      def side_fork
        unsettled = @source.active_turn || recoverable_tail
        edge = unsettled ? unsettled.position - 1 : @source.timeline_position_head - 1
        closure = child_closure(edge + 1)
        return Outcome.refused(:fork_too_large) if closure.any? { |e| e[:depth] > MAX_DEPTH }

        seed = overlay_seed_rows(edge + 1, closure)
        return Outcome.refused(:fork_too_large) if seed.length > MAX_OVERLAY_SEED

        target = unsettled || latest_turn_at_or_before(edge)
        # During regeneration the displayed active variant can be the previous
        # answer while a different candidate is doing the current work.
        chosen = unsettled&.conversation_turn_variants&.live
          &.find_by(status: ConversationTurnVariant::ACTIVE_STATUSES) || target&.active_variant
        # A side uses the current turn's answerer, or the last settled turn's
        # when idle, so its history renders from that answerer's perspective.
        # Empty history falls back to the source conversation's default.
        answerer_id = (unsettled || target)&.answering_user_id || @source.answering_user_id
        child = create_child(target, chosen, head: unsettled ? unsettled.position + 1 : edge + 1,
          side: true, answering_user_id: answerer_id)
        write_closure(child, closure)
        write_overlay(child, seed)
        copy_memory(child)
        copy_store_entries(child)
        copy_access_entries(child)
        if unsettled
          # Settlement, retry and compaction change the source graph under its
          # run lock. Conversation precedes run; the copy owns no execution FK.
          agent_run = chosen.agent_run
          if agent_run
            agent_run.with_lock { capture_reference(child, unsettled, chosen) }
          else
            capture_reference(child, unsettled, chosen)
          end
        end
        narrate(child, target, chosen)
        Outcome.accepted(child)
      end

      def capture_reference(child, turn, chosen)
        variant = adopt_boundary(child, turn, chosen, reference: true)
        ReferenceSnapshot.capture(turn: turn, source: chosen, target: variant)
      end

      # A hold releases active_turn before its loop becomes immutable. A delivered
      # reply, however, stays final while background tasks finish behind it.
      def recoverable_tail
        tail = @source.conversation_turns.order(position: :desc).first
        agent_run = tail&.active_variant&.agent_run
        tail if agent_run && !agent_run.terminal? && !agent_run.delivered?
      end

      # Undo leaves holes without moving the head. The latest existing turn
      # below the edge may therefore be in the inherited prefix.
      def latest_turn_at_or_before(position)
        return nil if position.negative?

        ConversationTurn.where(@source.timeline.reach)
          .where(position: ..position).order(position: :desc).first
      end

      # Reachable through the source's own read rule and effectively live:
      # an inherited target reads only the source's override, as the funnel does.
      def resolve_target
        turn = ConversationTurn.find_by(public_id: @command.turn_public_id)
        return nil if turn.nil?

        if turn.conversation_id == @source.id
          return nil if turn.deleted?

          turn
        else
          bound = @source.conversation_ancestries
            .find_by(ancestor_conversation_id: turn.conversation_id)&.boundary_position
          return nil if bound.nil? || turn.position > bound

          override = ConversationTurnOverride.find_by(
            conversation_id: @source.id, conversation_turn_id: turn.id
          )
          return nil if override&.deleted_at&.present?

          turn
        end
      end

      def resolve_variant(target)
        if @command.variant_public_id
          target.conversation_turn_variants.find_by(public_id: @command.variant_public_id)
        else
          target.active_variant
        end
      end

      # Memory copies pointer rows rather than reading through the closure:
      # an inherited turn cannot change, a memory document can, so
      # read-through would let a parent's later edit rewrite the child's memory.
      def copy_memory(child)
        rows = MemoryDocument.for_conversation(@source.id)
          .pluck(:name, :memory_document_version_id)
          .map do |name, version_id|
            { account_id: child.account_id, conversation_id: child.id,
              name: name, memory_document_version_id: version_id }
          end
        return if rows.empty?

        MemoryDocument.insert_all!(rows)
      end

      # Conversation-scope store entries are the CONVERSATION's client state
      # and fork with it — copied as current values with a fresh
      # `lock_version`, never shared: a store row is mutable, and
      # CoW-by-pointer (memory's rule) would let the parent's next PATCH
      # rewrite the child's value. Under the source's lock, which is also
      # the conversation host's create lock, so a create and this copy never
      # interleave. Workspace- and user-anchored rows are not the
      # conversation's and are not copied.
      def copy_store_entries(child)
        rows = StoreEntry.for_conversation(@source.id)
          .pluck(:namespace, :key, :value)
          .map do |namespace, key, value|
            { account_id: child.account_id, conversation_id: child.id,
              namespace: namespace, key: key, value: value, lock_version: 0 }
          end
        return if rows.empty?

        StoreEntry.insert_all!(rows)
      end

      # THE ACCESS CARRIER FORKS WITH THE CONVERSATION: rows copied at the
      # fork instant like the store's, never re-derived — a parent lookup
      # would let a later change on the source re-cut who reads a child
      # its writer never touched. Every principal's effective level on the
      # child equals its level on the source, except the forker, who
      # becomes the creator: the source's DERIVED-full principals (its
      # creator, its answerer) are MATERIALIZED as `full` rows unless they
      # are the child's own creator or answerer, and the forker's own row
      # is dropped — without the first, a Human who opened `default: none`
      # would be concealed from the answerer's own side of that
      # conversation. Under the source's lock, which is also the access
      # writer's, so a change and this copy never interleave.
      def copy_access_entries(child)
        levels = ConversationAccessEntry.where(conversation_id: @source.id).pluck(:user_id, :level).to_h
          .merge(@source.creating_user_id => "full", @source.answering_user_id => "full")
          .except(child.creating_user_id, child.answering_user_id)
        rows = levels.map do |user_id, level|
          { account_id: child.account_id, conversation_id: child.id, user_id: user_id, level: level }
        end
        return if rows.empty?

        ConversationAccessEntry.insert_all!(rows)
      end

      # The child's closure: the source at bound P-1 (the adopted turn
      # replaces position P), plus every source ancestor capped at the new
      # edge — copied, never recursed.
      def child_closure(target_position)
        edge = target_position - 1
        closure = [{ ancestor_conversation_id: @source.id, depth: 1, boundary_position: edge }]
        @source.conversation_ancestries
          .pluck(:ancestor_conversation_id, :depth, :boundary_position)
          .each do |ancestor_id, depth, bound|
            closure << {
              ancestor_conversation_id: ancestor_id,
              depth: depth + 1,
              boundary_position: [bound, edge].min,
            }
          end
        closure
      end

      # Every prefix row whose effective view in the source differs from the
      # default — its non-default local rows and its overrides, as the funnel reads them.
      def overlay_seed_rows(target_position, closure)
        edge = target_position - 1
        rows = ConversationTurn
          .where(conversation_id: @source.id, position: ..edge)
          .where("visibility <> 'visible' OR deleted_at IS NOT NULL")
          .pluck(:id, :visibility, :deleted_at)
          .map { |id, visibility, deleted_at| seed_row(id, visibility, deleted_at) }

        bounds = closure.to_h { [_1[:ancestor_conversation_id], _1[:boundary_position]] }
        ConversationTurnOverride
          .where(conversation_id: @source.id)
          .joins(:conversation_turn)
          .pluck("conversation_turns.conversation_id", "conversation_turns.position",
            :conversation_turn_id, :visibility, :deleted_at)
          .each do |ancestor_id, position, turn_id, visibility, deleted_at|
            bound = bounds[ancestor_id]
            next if bound.nil? || position > bound

            rows << seed_row(turn_id, visibility, deleted_at)
          end
        rows
      end

      def seed_row(turn_id, visibility, deleted_at)
        { conversation_turn_id: turn_id, visibility: visibility, deleted_at: deleted_at }
      end

      def create_child(target, chosen, head: target.position + 1, side: false,
                       answering_user_id: @source.answering_user_id)
        child = Conversation.create!(
          workspace: @source.workspace,
          creating_user: @command.acting_user,
          title: @command.title.presence || @source.title,
          side: side,
          forked_from_turn_public_id: target&.public_id,
          forked_from_variant_public_id: chosen&.public_id,
          timeline_position_head: head,
          # A fork COPIES its source's runner binding: the forked history
          # was produced on that filesystem. Never re-derived.
          default_runner_executor_id: @source.default_runner_executor_id,
          # And its ANSWERER: the child answers as its source does —
          # copied, never re-derived; without this line the model's
          # default would make the FORKER the answerer. A SIDE copies the
          # fork-point TURN's answerer instead.
          answering_user_id: answering_user_id,
          # And its ACCESS DEFAULT: the entries follow in `copy_access_entries`,
          # under the same rule — copied, never re-derived.
          access_default: @source.access_default,
          memory_context: @source.memory_context,
          **branch_root_billing
        )
        # Born with its cursor, as every host is.
        child.create_conversation_event_cursor!(account: child.account)
        child
      end

      # Fork copies the BRANCH ROOT's billing pair (the recorded checklist),
      # never re-verifying: attribution was settled when the root accepted it.
      def branch_root_billing
        root = @source.conversation_ancestries.order(depth: :desc).first
          &.ancestor_conversation || @source
        {
          billing_subject_key: root.billing_subject_key,
          billing_subject_public_id: root.billing_subject_public_id,
        }
      end

      def write_closure(child, closure)
        ConversationAncestry.insert_all!(closure.map { |edge|
          edge.merge(account_id: child.account_id, conversation_id: child.id)
        })
      end

      # Ordinary forks adopt an editable, regenerable message; a Side reference
      # stays immutable and owns no execution. Both preserve the original
      # speaker, origin, sender stamp and answerer.
      def adopt_boundary(child, target, chosen, reference: false)
        model = AgentRuns::CurrentModel.for_variant(chosen)
        turn = ConversationTurn.create!(
          account: child.account,
          conversation: child,
          position: target.position,
          # A running summarizer's sealed reference is not a completed summary
          # and must never cut the inherited history it has not summarized yet.
          kind: reference && target.compaction_summary? ? "message" : target.kind,
          role: target.role,
          status: "completed",
          speaker: target.speaker,
          control_owner_user: @command.acting_user,
          answering_user_id: target.answering_user_id,
          origin: target.origin,
          sender_conversation_public_id: target.sender_conversation_public_id,
          sender_run_public_id: target.sender_run_public_id,
          sender_task_key: target.sender_task_key,
          forked_from_turn_public_id: target.public_id,
          forked_from_variant_public_id: chosen.public_id,
        )
        variant = ConversationTurnVariant.create!(
          account: child.account,
          conversation_turn: turn,
          position: 0,
          status: "completed",
          source: "fork",
          context_mode: chosen.context_mode,
          memory_context: chosen.memory_context,
          provider_id: model.provider_id,
          model_ref: model.model_ref,
          reasoning_effort: model.reasoning_effort,
          reasoning_enabled: model.reasoning_enabled,
          content_preview: chosen.content_preview,
          content_size_bytes: chosen.content_size_bytes,
        )
        bodies = chosen.content_bodies.order(:id)
        bodies = bodies.where(role: %w[prompt preface]) if reference
        bodies.each do |body|
          ContentBodies::CloneSealed.call(source: body, owner: variant, role: body.role)
        end
        turn.update!(active_variant: variant)
        variant
      end

      def write_overlay(child, seed)
        return if seed.empty?

        ConversationTurnOverride.insert_all!(seed.map { |row|
          row.merge(account_id: child.account_id, conversation_id: child.id)
        })
      end

      # The fork narrates in the SOURCE's stream — a child starts an empty
      # stream by design. The child's public id is the replay key. A side
      # of a first-turn parent names no turn.
      def narrate(child, target, chosen)
        ConversationEvent::Append.call(
          host: @source,
          idempotency_key: child.public_id,
          items: [{
            type: "fork_created",
            payload: {
              "child_conversation_public_id" => child.public_id,
              "side" => (true if child.side?),
              "forked_from_turn_public_id" => target&.public_id,
              "forked_from_variant_public_id" => chosen&.public_id,
            }.compact,
          }]
        )
      end
  end
end
