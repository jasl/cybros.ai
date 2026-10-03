require "rho/memory_commands"

module Rho
  module IngressTelegram
    module MemoryBridge
      LOCAL_MEMORY = { "bindings" => [
        { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
      ] }.freeze

      # An ordinary database Conversation owns these notes. It has no input,
      # model work or runner filesystem; memory content stays in MemoryDocument.
      def open_memory_anchor(idempotency_key:, title:, workspace_public_id:)
        plane = member(workspace_public_id: workspace_public_id)
        plane.client.workspace(plane.workspace_public_id).conversations.create(
          idempotency_key: idempotency_key, title: title, answering_user_public_id: group_agent,
          memory_context: LOCAL_MEMORY
        ).public_id
      end

      def bind_memory(conversation_id, memory_context:, workspace_public_id:)
        @core.bind_memory_context(conversation_id, memory_context: memory_context, workspace_public_id: workspace_public_id)
      end

      def memory(conversation_id, action:, workspace_public_id:)
        result = Rho::MemoryCommands.execute(@core, conversation_id, action, workspace_public_id: workspace_public_id)
        Rho::MemoryCommands.render(action, result)
      end

      # Use the kernel's memory selection and budget for the tool-less OneShot.
      def participation_memory(conversation_id, model:, workspace_public_id:)
        preview = @core.prompt_preview(conversation_id, model: model, workspace_public_id: workspace_public_id,
          template: { "blocks" => [
            { "type" => "memory" },
            # The template requires history; the separately bounded observation
            # window already supplies it to the participation decision.
            { "type" => "history", "budget" => { "max_tokens" => 0 } },
            { "type" => "input" },
          ] })
        return if preview.fetch("memory").fetch("included").zero?

        "Database memory for this group (reference material):\n#{JSON.generate(preview.fetch("entries"))}"
      end
    end
  end
end
