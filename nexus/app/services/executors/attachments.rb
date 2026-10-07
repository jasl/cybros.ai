module Executors
  # Bound files available to one loop. The existing ContentBody joins
  # are the authority; an account-wide upload id alone grants no access.
  module Attachments
    module_function

    def fetch(agent_run:, public_id:)
      upload = agent_run.account.content_uploads.with_attached_file.find_by!(public_id: public_id)
      raise ActiveRecord::RecordNotFound unless upload.file.attached? && bound?(upload, agent_run)

      upload
    end

    def bound?(upload, agent_run)
      bodies = upload.content_bodies
      return true if bodies.where(role: %w[input output], agent_run_task_id: agent_run.agent_run_tasks.select(:id)).exists?

      variant = agent_run.conversation_turn_variant
      return false unless variant
      return true if bodies.where(conversation_turn_variant: variant, role: "prompt").exists?

      turn = variant.conversation_turn
      previous = Conversation::Timeline.new(turn.conversation).visible_turns(surface: :assembly)
        .where(conversation_turns: { position: ...turn.position })
        .unscope(:select, :order).select(:active_variant_id)
      return true if bodies.where(conversation_turn_variant_id: previous, role: %w[prompt content reference]).exists?

      # A capture is still a readable file after its native part leaves
      # model context. Use the same visible active variants as input files,
      # independent of replay's budget, compaction cut or answerer.
      loops = AgentRun.where(conversation_turn_variant_id: previous)
      nodes = AgentRunTask.where(agent_run_id: loops.select(:id))
      bodies.where(role: "output", agent_run_task_id: nodes.select(:id)).exists?
    end
  end
end
