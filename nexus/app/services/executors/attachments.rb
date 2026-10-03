module Executors
  # Bound input files available to one loop. The existing ContentBody joins
  # are the authority; an account-wide upload id alone grants no access.
  module Attachments
    module_function

    def fetch(agent_loop:, public_id:)
      upload = agent_loop.account.content_uploads.with_attached_file.find_by!(public_id: public_id)
      raise ActiveRecord::RecordNotFound unless upload.file.attached? && bound?(upload, agent_loop)

      upload
    end

    def bound?(upload, agent_loop)
      bodies = upload.content_bodies
      return true if bodies.where(role: "input", agent_loop_node_id: agent_loop.agent_loop_nodes.select(:id)).exists?

      variant = agent_loop.conversation_turn_variant
      return false unless variant
      return true if bodies.where(conversation_turn_variant: variant, role: "prompt").exists?

      turn = variant.conversation_turn
      previous = Conversation::Timeline.new(turn.conversation).visible_turns(surface: :assembly)
        .where(conversation_turns: { position: ...turn.position })
        .unscope(:select, :order).select(:active_variant_id)
      bodies.where(conversation_turn_variant_id: previous, role: %w[prompt content]).exists?
    end
  end
end
