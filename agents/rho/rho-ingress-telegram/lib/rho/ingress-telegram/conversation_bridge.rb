module Rho
  module IngressTelegram
    # Conversation controls use the same Core doors as the other rho surfaces.
    module ConversationBridge
      def search_conversations(query:, after: nil, workspace_public_id:)
        @core.search_conversations(query: query, after: after, limit: 50, archived: "include", workspace_public_id: workspace_public_id)
      end

      def history(id, before_position: nil, workspace_public_id:)
        @core.history(id, before_position: before_position, limit: 10, workspace_public_id: workspace_public_id)
      end

      def history_turn(id, reference: nil, workspace_public_id:)
        if reference.nil?
          page = @core.turns(id, latest: true, limit: 1, workspace_public_id: workspace_public_id)
        else
          position = Integer(reference, exception: false)
          raise Rho::Error, "Use a turn position from /history." unless position && position >= 0

          page = @core.turns(id, after_position: (position - 1 if position.positive?), limit: 1, workspace_public_id: workspace_public_id)
        end
        row = page.fetch("turns").last
        row if row && (reference.nil? || row.fetch("position") == position)
      end

      def isolated_history_turn?(turn)
        turn["answering_user_public_id"] == group_agent && !turn.dig("active_variant", "memory_context").nil?
      end

      def rename_conversation(id, title:, workspace_public_id:)
        @core.update_conversation(id, title: title, workspace_public_id: workspace_public_id)
      end

      def conversation_code_mode(id, workspace_public_id:)
        @core.conversation_code_mode(id, workspace_public_id: workspace_public_id)
      end

      def update_conversation_code_mode(id, code_mode:, workspace_public_id:)
        @core.update_conversation_code_mode(id, code_mode: code_mode, workspace_public_id: workspace_public_id)
      end

      def archive_conversation(id, workspace_public_id:)
        @core.archive_conversation(id, workspace_public_id: workspace_public_id)
      end

      def restore_conversation(id, workspace_public_id:)
        @core.unarchive_conversation(id, workspace_public_id: workspace_public_id)
      end

      def fork_conversation(id, turn, idempotency_key:, workspace_public_id:)
        @core.rewind(id, turn, keep_checkpoints: true, idempotency_key: idempotency_key, workspace_public_id: workspace_public_id)
      end

      def regenerate(id, turn, idempotency_key:, workspace_public_id:)
        @core.regenerate(id, turn, idempotency_key: idempotency_key, keep_checkpoints: true, workspace_public_id: workspace_public_id)
      end

      def variants(id, turn, workspace_public_id:)
        @core.variants(id, turn, workspace_public_id: workspace_public_id)
      end

      def activate_variant(id, turn, variant, workspace_public_id:)
        @core.activate_variant(id, turn, variant, workspace_public_id: workspace_public_id)
      end

      def candidate_view_state(id, turn, variant, concealed:, workspace_public_id:)
        @core.variant(id, turn, variant, concealed: concealed, workspace_public_id: workspace_public_id)
      end

      def edit_turn(id, turn, text:, workspace_public_id:)
        @core.edit_turn(id, turn, text: text, workspace_public_id: workspace_public_id)
      end

      def delete_turn(id, turn, workspace_public_id:)
        @core.delete_turn(id, turn, workspace_public_id: workspace_public_id)
      end

      def turn_view_state(id, turn, workspace_public_id:, **fields)
        @core.turn_view_state(id, turn, workspace_public_id: workspace_public_id, **fields)
      end

      def execution_control(action, run_id, task_key: nil, workspace_public_id:)
        if task_key
          @core.public_send(action, run_id, task_key, workspace_public_id: workspace_public_id)
        else
          @core.public_send(action, run_id, workspace_public_id: workspace_public_id)
        end
      end

      def transcript(run_id, before: nil, prefix: nil, workspace_public_id:)
        @core.transcript(run_id, limit: 10, before: before, prefix: prefix, workspace_public_id: workspace_public_id)
      end

      def context_preview(id, model:, isolated: false, workspace_public_id:)
        @core.prompt_preview(id, model: model, to: (group_agent if isolated), workspace_public_id: workspace_public_id)
      end

      def compact(id, workspace_public_id:)
        @core.compact(id, workspace_public_id: workspace_public_id)
      end
    end
  end
end
