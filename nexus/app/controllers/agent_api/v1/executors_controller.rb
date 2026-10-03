# AUTHORIZED DISCOVERY: the executors the acting principal may address — a
# runner to bind, a provider whose pool serves it — with what each
# announced. Member plane, account-level beside `tools` and `models`: which
# executors exist is not a workspace's fact. Filtered by ELIGIBILITY, never
# by presence (`presence`/`last_seen_at` are shown, never used to choose);
# a credential-less row is never offered; an ineligible or foreign id
# conceals as absence. No pagination: the set is an account's machines,
# small by construction.
class AgentAPI::V1::ExecutorsController < AgentAPI::V1::BaseController
  serves_plane :member

  def index
    live_server_ids = NexusServer.live_ids
    render json: {
      executors: addressable.map { |executor| AgentAPI::ExecutorPresenter.discovery(executor, live_server_ids:) },
    }
  end

  def show
    executor = addressable.find { |candidate| candidate.public_id == params[:public_id] }
    return render_not_found if executor.nil?

    render json: {
      executor: AgentAPI::ExecutorPresenter.discovery(executor, live_server_ids: NexusServer.live_ids),
    }
  end

  private

    def acting_user = current_credential.user

    # The eligibility predicate reads credential readiness and the shutdown
    # fence, which are not SQL (Executors::Pool's reason) — so the account's
    # machine rows are loaded and filtered in Ruby, readiness projected once.
    def addressable
      rows = TaskExecutor.live.where(account_id: acting_user.account_id, executor_kind: kinds).order(:id).preload(:manager).to_a
      readiness = TaskExecutor.credential_readiness_for(rows)
      rows.select { |executor| executor.eligible_for?(acting_user, readiness:) }
    end

    # Absent = both machine kinds; anything else — an agent address binds
    # nothing and is nobody's to address — is the caller's 400.
    def kinds
      kind = params[:kind]
      return TaskExecutor::MACHINE_KINDS if kind.nil?
      raise APIErrors::ParameterInvalid, :kind unless TaskExecutor::MACHINE_KINDS.include?(kind)

      [kind]
    end
end
