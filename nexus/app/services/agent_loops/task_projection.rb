module AgentLoops
  # Facts shared by task reads, durable transitions and ephemeral frames.
  module TaskProjection
    PUBLIC_STATUSES = { "queued" => "waiting" }.freeze

    class << self
      # `queued` is the engine's word; public readers know it as `waiting`.
      def public_status(status) = PUBLIC_STATUSES.fetch(status, status)

      # The fact as ONE nested block, shared with the `task_status` item:
      # the origin, the deciding principal (a `human|agent` grant alone)
      # and the time; a denial's reason is the row's `error.detail`, not
      # repeated here. Compact, and absent until a decision.
      def approval_projection(node)
        return nil if node.approval_origin.blank?

        {
          "origin" => node.approval_origin,
          "decided_by" => node.approved_by_user&.public_id,
          "decided_at" => node.approval_decided_at&.iso8601,
        }.compact
      end
    end
  end
end
