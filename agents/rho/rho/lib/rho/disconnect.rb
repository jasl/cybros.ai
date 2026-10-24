require "cybros_agent"

module Rho
  # `rho disconnect` revokes the connection owner's credentials and forgets
  # them only after successful revocation. OAuth revokes its refresh lineage;
  # API keys revoke their individual tokens.
  #
  # ONE FLOW for the daemon's route (which adds the in-flight refusal and
  # the lineage edges) and the daemon-less CLI (under the boot lock). What
  # it leaves behind is counted before the revoke: the unclaimed rows
  # addressed to the runner park to their deadline (accepted tasks retain their targets).
  module Disconnect
    Result = Data.define(:revoked, :unclaimed, :runner_executor_public_id, :identity)

    module_function

    # `credentials` is the SDK credential owner; `identity` its
    # identity; `executor_client` builds the runner's inbox reader.
    def call(home:, identity:, credentials:, executor_client:, log: nil)
      unclaimed = unclaimed_count(credentials, executor_client, log)
      revoked = []
      if credentials
        credentials.revoke
        revoked << "agent"
      end
      Rho::StateFile.new(home.connection_pointer_path).delete
      identity.session.delete
      Result.new(revoked: revoked, unclaimed: unclaimed,
        runner_executor_public_id: identity.runner_executor_public_id, identity: identity)
    end

    # ONE `inbox.list` on the runner credential; a read that fails costs
    # the count, never the disconnect.
    def unclaimed_count(credentials, executor_client, log)
      return 0 unless credentials

      page = executor_client.call(credentials.executor_credential).inbox.list
      page.items.count { |row| !row.claimed }
    rescue CybrosAgent::Error => error
      log&.warn("disconnect.inbox_unread", error_class: error.class.name)
      0
    end
  end
end
