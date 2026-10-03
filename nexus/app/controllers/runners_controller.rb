class RunnersController < Runners::BaseController
  PAGE_SIZE = 10

  def index
    @runners_pagy, @runners = pagy(
      :offset,
      Current.user.managed_runners.live.order_by_recency,
      limit: PAGE_SIZE
    )
    @runner_credential_readiness = TaskExecutor.credential_readiness_for(@runners)
  end

  # Terminal for the address itself: reconnecting the same registration
  # creates a different runner rather than reviving this one.
  def destroy
    runner.revoke
    redirect_to runners_path, notice: t(".revoked")
  end
end
