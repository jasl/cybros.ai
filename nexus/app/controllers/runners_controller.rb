class RunnersController < Runners::BaseController
  PAGE_SIZE = 10

  def index
    filters = params.permit(:kind, :status)
    @kind = filters[:kind].presence
    @status = filters[:status].presence || "active"
    machines = Current.user.managed_executors.preload(:assignment_agent).order_by_recency
    machines = machines.where(executor_kind: @kind) if @kind
    machines = machines.where(status: @status) unless @status == "all"
    @runners_pagy, @runners = pagy(
      :offset,
      machines,
      limit: PAGE_SIZE
    )
    @runner_credential_readiness = Executor.credential_readiness_for(@runners)
  end

  def show
    @runner = runner
    @measured_at = Time.current
    readiness = Executor.credential_readiness_for([@runner], now: @measured_at)
    @runner_facts = API::RunnerPresenter.full(@runner, principal: Current.user,
      readiness: readiness, live_server_ids: NexusServer.live_ids)
    assigned_agent = @runner.assignment_agent
    @key_agent = assigned_agent if assigned_agent && !assigned_agent.named_agent? && assigned_agent.steward_id == Current.user.id
    @run_counts = Run.visible_to(Current.user).for_executor(@runner.public_id).group(:status).count
  end

  # Terminal for the address itself: reconnecting the same registration
  # creates a different runner rather than reviving this one.
  def destroy
    runner.revoke
    redirect_to runner_path(runner), notice: t(".revoked")
  end
end
