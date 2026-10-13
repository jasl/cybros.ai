require "cybros_agent"

module Rho
  # `rho disconnect [--runner]`, the pair of `connect`: revoke
  # every stored lineage's refresh token on Nexus (`POST /oauth/revoke` —
  # the family dies; the row stays `active` and re-pairable, and readiness
  # makes it ineligible, so a create naming it is refused) and forget
  # it — revoked secrets are not kept. `--runner` revokes the runner lineage
  # alone and rewrites the pointer's mode `full` → `agent`, so the next
  # full-mode boot is recoverable and `rho connect` re-pairs the runner.
  #
  # ONE FLOW for the daemon's route (which adds the in-flight refusal and
  # the lineage edges) and the daemon-less CLI (under the boot lock). What
  # it leaves behind is counted before the revoke: the unclaimed rows
  # addressed to the runner park to their deadline (accepted tasks retain their targets).
  module Disconnect
    Result = Data.define(:revoked, :unclaimed, :runner_executor_public_id, :identity, :mode)

    module_function

    # `credentials` is the `Rho::Credentials` holder; `identity` its
    # identity; `executor_client` builds the runner's inbox reader.
    def call(home:, identity:, credentials:, runner_only:, executor_client:, log: nil)
      unclaimed = unclaimed_count(credentials, executor_client, log)
      revoked = []
      if credentials.runner?
        credentials.runner.revoke
        revoked << "runner"
      end
      if runner_only
        remaining = identity.runner_mode? ? identity : identity.without_runner
        Rho::StateFile.new(home.connection_pointer_path).write(remaining.pointer_document)
        remaining.record(clock: -> { Time.now })
        return Result.new(revoked: revoked, unclaimed: unclaimed,
          runner_executor_public_id: identity.runner_executor_public_id, identity: remaining, mode: remaining.mode)
      end

      if credentials.agent?
        credentials.agent.revoke
        revoked << "agent"
      end
      Rho::StateFile.new(home.connection_pointer_path).delete
      identity.session.delete
      Result.new(revoked: revoked, unclaimed: unclaimed,
        runner_executor_public_id: identity.runner_executor_public_id, identity: identity, mode: identity.mode)
    end

    # ONE `inbox.list` on the runner credential; a read that fails costs
    # the count, never the disconnect.
    def unclaimed_count(credentials, executor_client, log)
      return 0 unless credentials.runner?

      page = executor_client.call(credentials.runner_credential).inbox.list
      page.items.count { |row| !row.claimed }
    rescue CybrosAgent::Error => error
      log&.warn("disconnect.inbox_unread", error_class: error.class.name)
      0
    end
  end
end
