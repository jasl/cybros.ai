class API::V1::RunnersController < API::V1::BaseController
  include AgentAPI::KeysetPagination

  def index
    fields = params.permit(:kind, :status)
    scope = managed_runners
    if fields[:kind].present?
      kind = fields[:kind].to_s
      # This management collection accepts only the two machine kinds.
      raise APIErrors::ParameterInvalid, :kind unless Executor::MACHINE_KINDS.include?(kind)

      scope = scope.where(executor_kind: kind)
    end
    if fields[:status].present?
      status = fields[:status].to_s
      raise APIErrors::ParameterInvalid, :status unless Executor.statuses.key?(status)

      scope = scope.where(status: status)
    end
    page = keyset_page(scope, columns: { public_id: :uuid })
    measured_at = Time.current
    readiness = Executor.credential_readiness_for(page.records, now: measured_at)
    live_server_ids = NexusServer.live_ids
    render json: {
      runners: page.records.map { |runner| API::RunnerPresenter.basic(runner,
        principal: Current.user, readiness: readiness, live_server_ids: live_server_ids) },
      pagination: { next_after: page.next_after },
      measured_at: measured_at,
    }
  end

  def show
    runner = managed_runners.find_by!(public_id: params[:id])
    measured_at = Time.current
    readiness = Executor.credential_readiness_for([runner], now: measured_at)
    render json: {
      runner: API::RunnerPresenter.full(runner, principal: Current.user,
        readiness: readiness, live_server_ids: NexusServer.live_ids),
      measured_at: measured_at,
    }
  end

  private

    def managed_runners
      Current.user.managed_executors.preload(:manager)
    end
end
