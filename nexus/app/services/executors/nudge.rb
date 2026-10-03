module Executors
  # The cable's two frames, on the EXECUTOR's own stream: they name where
  # to look — the inbox is the one truth — and carry no work, so a publish
  # failure is swallowed: the executor's next inbox read loses nothing.
  # `work_available` goes to the addressee at dispatch; `work_canceled` to
  # the CLAIMANT when a stop or a branch cancel takes a claimed row away,
  # so it kills what it spawned. An unclaimed canceled row simply leaves
  # the inbox — the fact is the row.
  module Nudge
    WORK_AVAILABLE = "work_available".freeze
    WORK_CANCELED = "work_canceled".freeze

    module_function

    # Names the kind and the task, not merely the loop, so a runner claims
    # it directly instead of paging the inbox; a row with no addressee — a
    # kernel row — nudges nobody. A POOL row fans the same event to every
    # member's own stream, the members read by the one reader addressing
    # used — after commit, outside the loop lock.
    def work_available(node)
      event = { type: WORK_AVAILABLE, kind: node.inbox_kind,
                agent_loop_public_id: node.agent_loop.public_id,
                task_key: node.node_key, tool_name: node.tool_name }.compact
      if Pool.row?(node)
        principal = node.agent_loop.answering_user
        ApplicationRecord.current_transaction.after_commit do
          Pool.members(node.tool_name, principal).each { |member| publish(member.public_id, event) }
        end
        return
      end

      executor_public_id = node.addressed_executor&.public_id
      return if executor_public_id.nil?

      ApplicationRecord.current_transaction.after_commit { publish(executor_public_id, event) }
    end

    def work_canceled(node)
      return if node.claimed_at.blank?

      executor_public_id = node.claimed_by_executor_public_id
      event = { type: WORK_CANCELED, agent_loop_public_id: node.agent_loop.public_id,
                task_key: node.node_key }
      ApplicationRecord.current_transaction.after_commit { publish(executor_public_id, event) }
    end

    def publish(executor_public_id, event)
      ActionCable.server.broadcast(
        Nexus::RealtimeStreams.executor_inbox(executor_public_id), { event: event }
      )
    rescue StandardError => error
      Rails.error.report(error, handled: true,
        context: { event: "executor_inbox_nudge_failed", loop: event[:agent_loop_public_id] })
    end
  end
end
