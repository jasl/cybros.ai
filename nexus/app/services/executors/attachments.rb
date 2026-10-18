module Executors
  # Bound files available to one loop. The existing ContentBody joins
  # are the authority; an account-wide upload id alone grants no access.
  module Attachments
    module_function

    def fetch(run:, public_id:)
      upload = run.account.content_uploads.with_attached_file.find_by!(public_id: public_id)
      raise ActiveRecord::RecordNotFound unless upload.file.attached? && bound?(upload, run)

      upload
    end

    def bound?(upload, run)
      bodies = upload.content_bodies
      return true if bodies.where(role: %w[input output], task_id: run.tasks.select(:id)).exists?

      variant = run.variant
      return false unless variant
      return true if bodies.where(variant: variant, role: "prompt").exists?

      turn = variant.turn
      previous = Conversation::Timeline.new(turn.conversation).visible_turns(surface: :assembly)
        .where(turns: { position: ...turn.position })
        .unscope(:select, :order).select(:active_variant_id)
      return true if bodies.where(variant_id: previous, role: %w[prompt content reference]).exists?

      # A capture is still a readable file after its native part leaves
      # model context. Use the same visible active variants as input files,
      # independent of replay's budget, compaction cut or answerer.
      loops = Run.where(variant_id: previous)
      nodes = Task.where(run_id: loops.select(:id))
      bodies.where(role: "output", task_id: nodes.select(:id)).exists?
    end
  end
end
