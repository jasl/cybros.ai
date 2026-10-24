module Executors
  # A host preference for future acceptance. Existing tasks own their targets.
  class DefaultRunner
    Command = Data.define(:host, :executor_public_id, :acting_user)

    def self.call(command)
      host = command.host
      actor = command.acting_user
      return Outcome.refused(:not_authorized) unless
        host.writable_by?(actor) && (!actor.agent? || host.execution_agent == actor)

      target = nil
      unless command.executor_public_id.nil?
        target = Executor.providing(:runner).where(account_id: host.account_id)
          .find_by(public_id: command.executor_public_id)
        return Outcome.refused(:runner_not_found) if target.nil?
        detail = ineligibility(target, host.answering_user)
        return Outcome.refused(:runner_not_eligible, detail: detail) if detail
      end
      host.set_default_runner(target, by: actor)
      Outcome.accepted(host)
    end

    def self.ineligibility(executor, principal)
      return "revoked" unless executor.active?
      readiness = Executor.credential_readiness_for([executor])
      return "no ready credential" unless readiness.fetch(executor.id) == :ready
      return "shutdown pending" if executor.shutdown_pending?

      "not in scope for this host's principal" unless executor.eligible_for_role?(:runner, principal, readiness: readiness)
    end
  end
end
