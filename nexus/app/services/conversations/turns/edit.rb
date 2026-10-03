module Conversations
  module Turns
    # An edit is a new variant sealed and activated — never a patch, and
    # never mid-history: history edits are fork + edit.
    class Edit
      Command = Data.define(:conversation, :turn_public_id, :entries, :acting_user)

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
        return Outcome.refused(:missing_input) if @command.entries.blank?

        result = nil
        @conversation = @command.conversation
        @conversation.with_lock(requires_new: true) do
          result = locked_edit
          raise ActiveRecord::Rollback unless result.accepted?
        end
        result
      end

      private

        def locked_edit
          return Outcome.refused(:not_found) if @conversation.tombstoned?
          return Outcome.refused(:conversation_archived) if @conversation.archived?

          turn = @conversation.conversation_turns
            .find_by(public_id: @command.turn_public_id)
          return Outcome.refused(:not_found) if turn.nil? || turn.deleted?
          return Outcome.refused(:branch_required) unless turn.tail?
          return Outcome.refused(:conversation_busy) unless turn.terminal?
          # A compaction summary stands in for everything before it, so
          # rewriting it would silently replace the whole history.
          return Outcome.refused(:kernel_authored) if turn.compaction_summary?

          origin = turn.active_variant
          model = AgentLoops::CurrentModel.for_variant(origin) if origin
          variant = ConversationTurnVariant.create!(
            account: @conversation.account,
            conversation_turn: turn,
            position: next_slot(turn),
            status: "completed",
            source: "edit",
            context_mode: origin&.context_mode || "assembled",
            memory_context: origin ? origin.memory_context : @conversation.memory_context,
            origin_variant_id: origin&.id,
            # The trio rides over so an edited turn stays regenerable with
            # a bare regenerate; the columns are create-frozen.
            provider_id: model&.provider_id,
            model_ref: model&.model_ref,
            reasoning_effort: model&.reasoning_effort,
          )
          body = ContentBodies::Replace.call(
            owner: variant, role: "content", entries: @command.entries, seal: true
          )
          return Outcome.refused(body.refusal) unless body.accepted?

          variant.update_content_preview(body.body.effective_text)
          carry_question(origin, variant)
          turn.update!(active_variant: variant, status: "completed")
          @conversation.update!(
            context_revision: @conversation.context_revision + 1,
            last_activity_at: Time.current
          )
          narrate(turn, variant)
          Outcome.accepted(variant)
        end

        def next_slot(turn)
          (turn.conversation_turn_variants.maximum(:position) || -1) + 1
        end

        # The seed is the TURN's question, the same for every candidate
        # answer: the candidate carries the origin's `prompt` body, and the
        # `preface` the question was asked behind (ContextAssembly::Preface),
        # so only the answer moves in later history.
        def carry_question(origin, variant)
          ["prompt", ContextAssembly::Preface::ROLE].each do |role|
            body = origin&.content_bodies&.find_by(role: role)
            ContentBodies::CloneSealed.call(source: body, owner: variant, role: role) if body
          end
        end

        def narrate(turn, variant)
          identity = { "turn_public_id" => turn.public_id, "variant_public_id" => variant.public_id }
          ConversationEvent::Append.call(
            host: @conversation,
            items: [
              { type: "turn_variant", payload: identity.merge("edited" => true, "activated" => true) },
              {
                type: "turn_status",
                payload: identity.merge(
                  "turn_kind" => turn.kind, "status" => turn.status, "variant_status" => variant.status
                ),
              },
            ]
          )
          TranscriptStream.settled_turn(turn, variant: variant)
        end
    end
  end
end
