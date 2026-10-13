# The executor plane's inbox transport: the credential names the executor,
# and the executor IS the standing — `executor_usable?` at authentication
# is the whole fence, there is no workspace gate. The scoped finder is the
# executor's ACCOUNT: a loop elsewhere is absence; a row inside the account
# addressed to another executor answers the typed conflict, because the row
# names its addressee.
class AgentAPI::V1::Executors::BaseController < AgentAPI::V1::BaseController
  serves_plane :executor_transport

  private

    def current_executor
      current_credential.task_executor
    end

    def find_addressable_loop
      AgentRun.where(account_id: current_executor.account_id)
        .find_by!(public_id: params.fetch(:run_public_id))
    end
end
