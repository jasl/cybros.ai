module Conversations
  module Turns
    # A local turn owns its view columns; an inherited one is touched only
    # through the override row. The service derives each cause into its
    # own wire code, and the model validations stay the forgetful-writer backstop.
    class SetViewState
      Command = Data.define(:conversation, :turn_public_id, :acting_user,
        :visibility, :concealed)

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
        if @command.visibility.nil? && @command.concealed.nil?
          return Outcome.refused(:nothing_to_change)
        end
        if @command.visibility && !ConversationTurn::VISIBILITIES.include?(@command.visibility)
          return Outcome.refused(:invalid_visibility)
        end

        @conversation = @command.conversation
        @conversation.with_lock do
          next Outcome.refused(:not_found) if @conversation.tombstoned?
          next Outcome.refused(:conversation_archived) if @conversation.archived?

          reach = TurnReach.resolve(
            conversation: @conversation, turn_public_id: @command.turn_public_id
          )
          next Outcome.refused(:not_found) if reach.nil?
          # Concealing a summary would un-compact the conversation through
          # a view flag; the undo is deleting the tail, kept in one place.
          next Outcome.refused(:kernel_authored) if reach.turn.compaction_summary?

          reach.inherited? ? apply_override(reach) : apply_local(reach)
        end
      end

      private

        # The reach IS the answer's value: the turn and which side of the
        # boundary it lives on.
        def apply_local(reach)
          turn = reach.turn
          # A row already in the requested concealment state is a TRUE
          # no-op — no write, no narration, and never a re-derivation the
          # model could refuse (the re-conceal-after-the-pin-died cell).
          conceal_change = !@command.concealed.nil? && @command.concealed != turn.deleted?
          visibility_change = @command.visibility.present? &&
            @command.visibility != turn.visibility
          unless conceal_change || visibility_change
            return Outcome.accepted(reach)
          end

          if conceal_change
            refusal = local_refusal(turn)
            return Outcome.refused(refusal) if refusal
          end

          before = in_assembly?(visibility: turn.visibility, deleted: turn.deleted?)
          changes = {}
          changes[:visibility] = @command.visibility if visibility_change
          if conceal_change
            changes[:deleted_at] = @command.concealed ? Time.current : nil
          end
          turn.update!(changes)

          finish(reach, before: before,
            after: in_assembly?(visibility: turn.visibility, deleted: turn.deleted?))
        end

        def apply_override(reach)
          turn = reach.turn
          override = ConversationTurnOverride.find_or_initialize_by(
            conversation_id: @conversation.id, conversation_turn_id: turn.id
          )
          override.account_id ||= @conversation.account_id
          override.visibility = "visible" if override.new_record?

          before = in_assembly?(
            visibility: override.persisted? ? override.visibility : "visible",
            deleted: override.persisted? && override.deleted_at.present?
          )
          override.visibility = @command.visibility if @command.visibility
          unless @command.concealed.nil?
            override.deleted_at = @command.concealed ? Time.current : nil
          end
          override.save!

          finish(reach, before: before,
            after: in_assembly?(
              visibility: override.visibility, deleted: override.deleted_at.present?
            ))
        end

        # The model rules as answerable codes, consulted only for a real
        # state change; restore and conceal each refuse for exactly one reason.
        def local_refusal(turn)
          if @command.concealed
            return :not_terminal unless turn.terminal?
            if apex?(turn) && !pinned?(turn)
              :apex_never_conceals
            end
          elsif @conversation.conversation_turns.live.above(turn.position).exists?
            :branch_required
          end
        end

        def apex?(turn)
          !@conversation.conversation_turns.above(turn.position).exists?
        end

        def pinned?(turn)
          ConversationAncestry
            .where(ancestor_conversation_id: @conversation.id, boundary_position: turn.position..)
            .exists?
        end

        def in_assembly?(visibility:, deleted:)
          !deleted && visibility == "visible"
        end

        def finish(reach, before:, after:)
          @conversation.update!(
            last_activity_at: Time.current,
            **(before == after ? {} : { context_revision: @conversation.context_revision + 1 })
          )
          narrate(reach.turn, inherited: reach.inherited?)
          Outcome.accepted(reach)
        end

        def narrate(turn, inherited:)
          items = []
          if @command.visibility
            items << { type: "visibility", payload: {
              "turn_public_id" => turn.public_id,
              "visibility" => @command.visibility,
              "inherited" => inherited,
            } }
          end
          unless @command.concealed.nil?
            items << { type: "soft_delete", payload: {
              "turn_public_id" => turn.public_id,
              "concealed" => @command.concealed,
              "inherited" => inherited,
            } }
          end
          return if items.empty?

          ConversationEvent::Append.call(host: @conversation, items: items)
        end
    end
  end
end
