# The reloadable connection context: only a grant this browser verified, so
# refresh and back cost no second exposure charge; terminal grants render
# safe state pages.
class OAuth::DeviceGrantsController < OAuth::BrowserController
  def show
    @grant = verified_grant(params[:id])

    if @grant.nil?
      redirect_to oauth_device_path, alert: t("oauth.device.unknown_grant")
      return
    end

    @grant.materialize_expiry
    @existing_runner = existing_runner_for(@grant)

    # `pending` is the only status that still asks the human for a decision;
    # every other one — including `connected`, which is not terminal at all —
    # renders the settled-state page, which branches on the status itself.
    if @grant.pending?
      if @grant.runner_only_connection?
        @expected_live_runner =
          DeviceAuthorizations::Connect.live_runner_precondition(@existing_runner)
      end
      render :show
    else
      render :settled
    end
  end

  private

    # A combined grant displays the existing scope without posting a runner
    # precondition. After Connect, the consequence belongs to its connector,
    # even if this browser signs in as another member.
    def existing_runner_for(grant)
      return if grant.agent_connection?
      return unless grant.pending? || grant.connected?

      TaskExecutor.runner_for(
        account_id: grant.account_id,
        manager_id: grant.connected_by_id || Current.user.id,
        registration_identifier: grant.registration_identifier
      )
    end
end
