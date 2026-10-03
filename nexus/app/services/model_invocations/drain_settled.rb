module ModelInvocations
  # THE ONE DRAIN of a host's settled invocation history: the caller holds
  # the HOST'S lock — a conversation's in `Conversations::Reap` and
  # `Workspaces::Collect`, a loop's in `AgentLoops::Reap` — and has proven
  # no unsettled work before handing in the host's own `model_invocations`
  # relation. The variant's frozen snapshot and the value-linked usage
  # receipts survive, which is why billing attribution is frozen onto them.
  # Answers the number of invocations removed.
  class DrainSettled
    def self.call(invocations)
      invocation_ids = invocations.order(:id).lock.pluck(:id)
      return 0 if invocation_ids.empty?

      ContentBody.where(model_invocation_id: invocation_ids).delete_all
      ModelInvocation.purge_output_files_later(invocation_ids)
      ModelInvocationAttempt.where(model_invocation_id: invocation_ids).delete_all
      ModelInvocation.where(id: invocation_ids).delete_all
      invocation_ids.length
    end
  end
end
