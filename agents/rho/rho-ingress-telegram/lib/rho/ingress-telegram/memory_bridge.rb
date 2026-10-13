require "rho/memory_commands"

module Rho
  module IngressTelegram
    module MemoryBridge
      def memory(conversation_id, action:, workspace_public_id:, speaker_public_id:)
        result = Rho::MemoryCommands.execute(@core, conversation_id, action, workspace_public_id: workspace_public_id, speaker_public_id: speaker_public_id)
        Rho::MemoryCommands.render(action, result)
      end

      # Use the kernel's memory selection and budget for the tool-less InferenceRequest.
      def participation_memory(conversation_id, model:, workspace_public_id:, speaker_public_id:)
        preview = @core.prompt_preview(conversation_id, model: model, workspace_public_id: workspace_public_id, speaker_public_id: speaker_public_id,
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
